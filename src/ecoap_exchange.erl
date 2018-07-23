-module(ecoap_exchange).

%% API
-export([init/2, received/3, send/3, timeout/3, awaits_response/1, in_transit/1, cancel_msg/1, not_expired/2]).
-export([idle/3, got_non/3, sent_non/3, got_rst/3, await_aack/3, pack_sent/3, await_pack/3, aack_sent/3, cancelled/3]).

-record(exchange, {
    timestamp = undefined :: integer(),
    expire_time = undefined :: undefined | non_neg_integer(),
    stage = undefined :: atom(),
    trid = undefined :: ecoap_endpoint:trid(),
    receiver = undefined :: undefined | ecoap_endpoint:receiver(),
    msgbin = <<>> :: binary(),
    timer = undefined :: undefined | reference(),
    retry_time = undefined :: undefined | non_neg_integer(),
    retry_count = undefined :: undefined | non_neg_integer()
    }).

-define(ACK_TIMEOUT(Config), map_get(ack_timeout, Config)).
-define(ACK_RANDOM_FACTOR(Config), map_get(ack_random_factor, Config)).
-define(MAX_RETRANSMIT(Config), map_get(max_retransmit, Config)).
-define(PROCESSING_DELAY(Config), map_get(processing_delay, Config)). 
-define(EXCHANGE_LIFETIME(Config), map_get(exchange_lifetime, Config)).
-define(NON_LIFETIME(Config), map_get(non_lifetime, Config)).

-type exchange() :: undefined | #exchange{}.

-export_type([exchange/0]).

-include("coap_message.hrl").

-spec not_expired(integer(), exchange()) -> boolean().
not_expired(CurrentTime, #exchange{timestamp=Timestamp, expire_time=ExpireTime}) ->
    CurrentTime - Timestamp < ExpireTime.

-spec init(ecoap_endpoint:trid(), undefined | ecoap_endpoint:receiver()) -> exchange().
init(TrId, Receiver) ->
    #exchange{timestamp=erlang:monotonic_time(), stage=idle, trid=TrId, receiver=Receiver}.

% process incoming message
-spec received(binary(), ecoap_endpoint:trans_args(), exchange()) -> exchange().
received(BinMessage, TransArgs, Exchange=#exchange{stage=Stage}) ->
    ?MODULE:Stage({in, BinMessage}, TransArgs, Exchange).

% process outgoing message
-spec send(coap_message:coap_message(), ecoap_endpoint:trans_args(), exchange()) -> exchange().
send(Message, TransArgs, Exchange=#exchange{stage=Stage}) ->
    ?MODULE:Stage({out, Message}, TransArgs, Exchange).

% process timeout
-spec timeout(atom(), ecoap_endpoint:trans_args(), exchange()) -> exchange().
timeout(Event, TransArgs, Exchange=#exchange{stage=Stage}) ->
    ?MODULE:Stage({timeout, Event}, TransArgs, Exchange).

% cancel msg
-spec cancel_msg(exchange()) -> exchange().
cancel_msg(Exchange) ->
    Exchange#exchange{stage=cancelled, msgbin = <<>>}.

% check if we can send a response
-spec awaits_response(exchange()) -> boolean().
awaits_response(#exchange{stage=await_aack}) ->
    true;
awaits_response(_Exchange) ->
    false.

% A CON is in transit as long as it has not been acknowledged, rejected, or timed out.
-spec in_transit(exchange()) -> boolean().
in_transit(#exchange{stage=await_pack}) -> 
    true;
in_transit(_Exchange) -> 
    false.

% ->NON
-spec idle({in, binary()} | {out, coap_message:coap_message()}, ecoap_endpoint:trans_args(), exchange()) -> exchange().
idle(Msg={in, <<1:2, 1:2, _:12, _Tail/bytes>>}, TransArgs, Exchange) ->
    in_non(Msg, TransArgs, Exchange#exchange{expire_time=?NON_LIFETIME(TransArgs)});
% ->CON
idle(Msg={in, <<1:2, 0:2, _:12, _Tail/bytes>>}, TransArgs, Exchange) ->
    in_con(Msg, TransArgs, Exchange#exchange{expire_time=?EXCHANGE_LIFETIME(TransArgs)});
% NON-> 
idle(Msg={out, #coap_message{type='NON'}}, TransArgs, Exchange) ->
    out_non(Msg, TransArgs, Exchange#exchange{expire_time=?NON_LIFETIME(TransArgs)});
% CON->
idle(Msg={out, #coap_message{type='CON'}}, TransArgs, Exchange) ->
    out_con(Msg, TransArgs, Exchange#exchange{expire_time=?EXCHANGE_LIFETIME(TransArgs)}).

% --- incoming NON
-spec in_non({in, binary()}, ecoap_endpoint:trans_args(), exchange()) -> exchange().
in_non({in, BinMessage}, TransArgs, Exchange) ->
    case catch {ok, coap_message:decode(BinMessage)} of
        {ok, #coap_message{code=Method}=Message} when is_atom(Method) ->
            handle_request(Message, TransArgs, Exchange);
        {ok, #coap_message{}=Message} ->
            handle_response(Message, TransArgs, Exchange);
        _ ->
            % shall we send reset?
            ok
    end,
    check_next_state(got_non, Exchange).

-spec got_non({in, binary()}, ecoap_endpoint:trans_args(), exchange()) -> exchange().
got_non({in, _Message}, _TransArgs, Exchange) ->
    % ignore retransmission
    next_state(got_non, Exchange).

% --- outgoing NON
-spec out_non({out, coap_message:coap_message()}, ecoap_endpoint:trans_args(), exchange()) -> exchange().
out_non({out, Message}, TransArgs, Exchange) ->
    %io:fwrite("~p send outgoing non msg ~p~n", [self(), Message]),
    BinMessage = coap_message:encode(Message),
    ok = send(TransArgs, BinMessage),
    check_next_state(sent_non, Exchange).

% we may get reset
-spec sent_non({in, binary()}, ecoap_endpoint:trans_args(), exchange()) -> exchange().
sent_non({in, BinMessage}, TransArgs, Exchange) ->
    case catch {ok, coap_message:decode(BinMessage)} of
        {ok, #coap_message{type='RST'}=Message} ->
            handle_error(Message, 'RST', TransArgs, Exchange),
            next_state(got_rst, Exchange);
        {ok, #coap_message{}} ->
            next_state(sent_non, Exchange);
        _ ->
            next_state(sent_non, Exchange)
    end.
            
-spec got_rst({in, binary()}, ecoap_endpoint:trans_args(), exchange()) -> exchange().
got_rst({in, _BinMessage}, _TransArgs, Exchange)->
    next_state(got_rst, Exchange).

% --- incoming CON->ACK|RST
-spec in_con({in, binary()}, ecoap_endpoint:trans_args(), exchange()) -> exchange().
in_con({in, BinMessage}, TransArgs, Exchange) ->
    case catch {ok, coap_message:decode(BinMessage)} of
        {ok, #coap_message{code=undefined}=Message} ->
            % provoked reset
            go_pack_sent(ecoap_request:rst(Message), TransArgs, Exchange);
        {ok, #coap_message{code=Method}=Message} when is_atom(Method) ->
            handle_request(Message, TransArgs, Exchange),
            go_await_aack(Message, TransArgs, Exchange);
        {ok, #coap_message{}=Message} ->
            handle_response(Message, TransArgs, Exchange),
            go_await_aack(Message, TransArgs, Exchange);
        _ ->
            go_pack_sent(ecoap_request:rst(coap_message:get_id(BinMessage)), TransArgs, Exchange)
    end.

-spec go_await_aack(coap_message:coap_message(), ecoap_endpoint:trans_args(), exchange()) -> exchange().
go_await_aack(Message, TransArgs, Exchange) ->
    % we may need to ack the message
    BinAck = coap_message:encode(ecoap_request:ack(Message)),
    next_state(await_aack, TransArgs, Exchange#exchange{msgbin=BinAck}, ?PROCESSING_DELAY(TransArgs)).

-spec await_aack({in, binary()} | {timeout, await_aack} | {out, coap_message:coap_message()}, ecoap_endpoint:trans_args(), exchange()) -> exchange().
await_aack({in, _BinMessage}, _TransArgs, Exchange) ->
    % ignore retransmission
    next_state(await_aack, Exchange);

await_aack({timeout, await_aack}, TransArgs, Exchange=#exchange{msgbin=BinAck}) ->
    io:fwrite("~p <- ack [application didn't respond]~n", [self()]),
    ok = send(TransArgs, BinAck),
    check_next_state(pack_sent, Exchange);

await_aack({out, Ack}, TransArgs, Exchange) ->
    % set correct type for a piggybacked response
    Ack2 = case Ack of
        #coap_message{type='CON'} -> Ack#coap_message{type='ACK'};
        _ -> Ack
    end,
    go_pack_sent(Ack2, TransArgs, Exchange).

-spec go_pack_sent(coap_message:coap_message(), ecoap_endpoint:trans_args(), exchange()) -> exchange().
go_pack_sent(Ack, TransArgs, Exchange) ->
	%io:fwrite("~p send ack/rst msg ~p~n", [self(), Ack]),
    BinAck = coap_message:encode(Ack),
    ok = send(TransArgs, BinAck),
    check_next_state(pack_sent, Exchange#exchange{msgbin=BinAck}).

% -spec go_rst_sent(coap_message:coap_message(), ecoap_endpoint:trans_args(), exchange()) -> exchange().
% go_rst_sent(RST, TransArgs, Exchange) ->
%     BinRST = coap_message:encode(RST),
%     ok = send(TransArgs, BinRST),
%     next_state(undefined, Exchange).

-spec pack_sent({in, binary()} | {timeout, await_aack}, ecoap_endpoint:trans_args(), exchange()) -> exchange().
pack_sent({in, _BinMessage}, TransArgs, Exchange=#exchange{msgbin=BinAck}) ->
    % retransmit the ack
    ok = send(TransArgs, BinAck),
    next_state(pack_sent, Exchange);
pack_sent({timeout, await_aack}, _TransArgs, Exchange) ->
	% in case the timeout msg was sent before we cancel the timer
	% ignore the msg
	next_state(pack_sent, Exchange).

% Note that, as the underlying datagram
% transport may not be sequence-preserving, the Confirmable message
% carrying the response may actually arrive before or after the
% Acknowledgement message for the request; for the purposes of
% terminating the retransmission sequence, this also serves as an
% acknowledgement.

% If the request message is Non-confirmable, then the response SHOULD
% be returned in a Non-confirmable message as well.  However, an
% endpoint MUST be prepared to receive a Non-confirmable response
% (preceded or followed by an Empty Acknowledgement message) in reply
% to a Confirmable request, or a Confirmable response in reply to a
% Non-confirmable request.

% TODO: CON->CON does not cancel retransmission of the request

% --- outgoing CON->ACK|RST
-spec out_con({out, coap_message:coap_message()}, ecoap_endpoint:trans_args(), exchange()) -> exchange().
out_con({out, Message}, TransArgs, Exchange) ->
    %io:fwrite("~p send outgoing con msg ~p~n", [self(), Message]),
    BinMessage = coap_message:encode(Message),
    ok = send(TransArgs, BinMessage),
    % _ = rand:seed(exs1024),
    Timeout = ?ACK_TIMEOUT(TransArgs)+rand:uniform(?ACK_RANDOM_FACTOR(TransArgs)),
    next_state(await_pack, TransArgs, Exchange#exchange{msgbin=BinMessage, retry_time=Timeout, retry_count=0}, Timeout).

% peer ack
-spec await_pack({in, binary()} | {timeout, await_pack}, ecoap_endpoint:trans_args(), exchange()) -> exchange().
await_pack({in, BinAck}, TransArgs, Exchange) ->
    case catch {ok, coap_message:decode(BinAck)} of
        {ok, #coap_message{type='ACK', code=undefined}=Message} ->
            % this is an empty ack for separate response or observe notification
            handle_ack(Message, TransArgs, Exchange),
            % since we can confirm when an outgoing confirmable message
            % has been acknowledged or reset, we can safely clean the msgbin 
            % which won't be used again from this moment
            check_next_state(aack_sent, Exchange#exchange{msgbin= <<>>});
        {ok, #coap_message{type='RST', code=undefined}=Message} ->
            handle_error(Message, 'RST', TransArgs, Exchange),
            check_next_state(aack_sent, Exchange#exchange{msgbin= <<>>});
        {ok, #coap_message{}=Message} ->
            handle_response(Message, TransArgs, Exchange),
            check_next_state(aack_sent, Exchange#exchange{msgbin= <<>>});
        _ ->
            % shall we inform the receiver the error?
            next_state(await_pack, Exchange)   
    end;

await_pack({timeout, await_pack}, TransArgs, Exchange=#exchange{msgbin=BinMessage, retry_time=Timeout, retry_count=Count}) when Count < ?MAX_RETRANSMIT(TransArgs) ->
    % BinMessage = coap_message:encode(Message),
    %io:fwrite("resend msg for ~p time~n", [Count]),
    ok = send(TransArgs, BinMessage),
    Timeout2 = Timeout*2,
    next_state(await_pack, TransArgs, Exchange#exchange{retry_time=Timeout2, retry_count=Count+1}, Timeout2);
await_pack({timeout, await_pack}, TransArgs, Exchange=#exchange{trid={out, MsgId}}) ->
    handle_error(ecoap_request:rst(MsgId), timeout, TransArgs, Exchange),
    check_next_state(aack_sent, Exchange#exchange{msgbin= <<>>}).

-spec aack_sent({in, binary()} | {timeout, await_pack}, ecoap_endpoint:trans_args(), exchange()) -> exchange().
aack_sent({in, _Ack}, _TransArgs, Exchange) ->
    % ignore ack retransmission
    next_state(aack_sent, Exchange);
aack_sent({timeout, await_pack}, _TransArgs, Exchange) ->
	% in case the timeout msg was sent before we cancel the timer
	% ignore the msg
	next_state(aack_sent, Exchange).

-spec cancelled({_, _}, ecoap_endpoint:trans_args(), exchange()) -> exchange().
cancelled({_, _}, _TransArgs, Exchange) ->
    Exchange.

% utility functions
handle_request(Message, 
    TransArgs=#{ep_id:=EpID, handler_sup:=HdlSupPid, endpoint_pid:=EndpointPid, handler_regs:=HandlerRegs}, #exchange{receiver=undefined}) ->
    %io:fwrite("handle_request called from ~p with ~p~n", [self(), Message]),
    HandlerConfig = ecoap_default:handler_config(TransArgs),
    HandlerID = ecoap_handler:handler_id(Message),
    case get_handler(HdlSupPid, HandlerConfig, HandlerID, HandlerRegs) of
        {ok, Pid} ->
            Pid ! {coap_request, EpID, EndpointPid, undefined, Message},
            ok;
        {error, _Error} ->
            {ok, _} = ecoap_endpoint:send(EndpointPid,
                ecoap_request:response({error, 'InternalServerError'}, Message)),
            ok
    end.

% it makes no sense to have the following code block because as a client we could not know the recevier of the request in advance
% handle_request(Message, #{ep_id:=EpID, endpoint_pid:=EndpointPid}, #exchange{receiver={Sender, Ref}}) ->
%     %io:fwrite("handle_request called from ~p with ~p~n", [self(), Message]),
%     Sender ! {coap_request, EpID, EndpointPid, Ref, Message},
%     ok.

handle_response(Message, #{ep_id:=EpID, endpoint_pid:=EndpointPid}, #exchange{receiver=Receiver={Sender, Ref}}) ->
    %io:fwrite("handle_response called from ~p with ~p~n", [self(), Message]),    
    Sender ! {coap_response, EpID, EndpointPid, Ref, Message},
    request_complete(EndpointPid, Message, Receiver).

handle_error(Message, Error, #{ep_id:=EpID, endpoint_pid:=EndpointPid}, #exchange{receiver=Receiver={Sender, Ref}}) ->
	%io:fwrite("handle_error called from ~p with ~p~n", [self(), Message]),
	Sender ! {coap_error, EpID, EndpointPid, Ref, Error},
	request_complete(EndpointPid, Message, Receiver).

handle_ack(_Message, #{ep_id:=EpID, endpoint_pid:=EndpointPid}, #exchange{receiver={Sender, Ref}}) ->
	%io:fwrite("handle_ack called from ~p with ~p~n", [self(), _Message]),
	Sender ! {coap_ack, EpID, EndpointPid, Ref},
	ok.

get_handler(SupPid, Config, HandlerID, HandlerRegs) ->
    case maps:find(HandlerID, HandlerRegs) of
        {ok, Pid} ->
            {ok, Pid};
        error ->          
            ecoap_handler_sup:start_handler(SupPid, [HandlerID, Config])
    end.

request_complete(EndpointPid, Message, Receiver) ->
    ecoap_endpoint:request_complete(EndpointPid, Receiver, coap_message:get_option('Observe', Message)).

send(#{sock:=Socket, sock_module:=SocketModule, ep_id:=EpID}, BinMessage) ->
    SocketModule:send(Socket, EpID, BinMessage).

timeout_after(Time, EndpointPid, TrId, Event) ->
    erlang:send_after(Time, EndpointPid, {timeout, TrId, Event}).

cancel_timer(Timer) ->
    erlang:cancel_timer(Timer, [{async, true}, {info, false}]).

check_next_state(_,  Exchange=#exchange{expire_time=0}) -> next_state(undefined, Exchange);
check_next_state(Stage, Exchange) -> next_state(Stage, Exchange).

% start the timer
next_state(Stage, #{endpoint_pid:=EndpointPid}, Exchange=#exchange{trid=TrId, timer=undefined}, Timeout) ->
    Timer = timeout_after(Timeout, EndpointPid, TrId, Stage),
    Exchange#exchange{stage=Stage, timer=Timer};
% restart the timer
next_state(Stage, #{endpoint_pid:=EndpointPid}, Exchange=#exchange{trid=TrId, timer=Timer1}, Timeout) ->
    _ = cancel_timer(Timer1),
    Timer2 = timeout_after(Timeout, EndpointPid, TrId, Stage),
    Exchange#exchange{stage=Stage, timer=Timer2}.

next_state(undefined, #exchange{timer=undefined}) ->
    undefined;
next_state(undefined, #exchange{timer=Timer}) ->
    _ = cancel_timer(Timer),
    undefined;
next_state(Stage, Exchange=#exchange{timer=undefined}) ->
    Exchange#exchange{stage=Stage};
next_state(Stage, Exchange=#exchange{stage=Stage1, timer=Timer}) ->
    if
        % when going to another stage, the timer is cancelled
        Stage /= Stage1 ->
            _ = cancel_timer(Timer),
            Exchange#exchange{stage=Stage, timer=undefined};
        % when staying in current stage, the timer continues
        true ->
            Exchange
    end.