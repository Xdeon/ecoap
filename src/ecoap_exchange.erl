-module(ecoap_exchange).

%% API
-export([init/2, received/3, send/3, timeout/3, awaits_response/1, in_transit/1, cancel_msg/1, not_expired/2]).
-export([idle/3, got_non/3, sent_non/3, got_rst/3, await_aack/3, pack_sent/3, await_pack/3, aack_sent/3, cancelled/3]).

-define(ACK_TIMEOUT, 2000).
-define(ACK_RANDOM_FACTOR, 1000). % ACK_TIMEOUT*0.5
-define(MAX_RETRANSMIT, 4).

-define(PROCESSING_DELAY, 1500). % standard allows 2000
-define(EXCHANGE_LIFETIME, 247000).
% -define(EXCHANGE_LIFETIME, 1500).
-define(NON_LIFETIME, 145000).

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

-type exchange() :: undefined | #exchange{}.

-export_type([exchange/0]).

-spec not_expired(integer(), exchange()) -> boolean().
not_expired(CurrentTime, #exchange{timestamp=Timestamp, expire_time=ExpireTime}) ->
    CurrentTime - Timestamp < ExpireTime.

-spec init(ecoap_endpoint:trid(), undefined | ecoap_endpoint:receiver()) -> exchange().
init(TrId, Receiver) ->
    #exchange{timestamp=erlang:monotonic_time(), stage=idle, trid=TrId, receiver=Receiver}.

% process incoming message
-spec received(binary(), ecoap_endpoint:trans_args(), exchange()) -> exchange().
received(BinMessage, TransArgs, State=#exchange{stage=Stage}) ->
    ?MODULE:Stage({in, BinMessage}, TransArgs, State).

% process outgoing message
-spec send(coap_message:coap_message(), ecoap_endpoint:trans_args(), exchange()) -> exchange().
send(Message, TransArgs, State=#exchange{stage=Stage}) ->
    ?MODULE:Stage({out, Message}, TransArgs, State).

% process timeout
-spec timeout(atom(), ecoap_endpoint:trans_args(), exchange()) -> exchange().
timeout(Event, TransArgs, State=#exchange{stage=Stage}) ->
    ?MODULE:Stage({timeout, Event}, TransArgs, State).

% cancel msg
-spec cancel_msg(exchange()) -> exchange().
cancel_msg(State) ->
    State#exchange{stage=cancelled, msgbin = <<>>}.

% check if we can send a response
-spec awaits_response(exchange()) -> boolean().
awaits_response(#exchange{stage=await_aack}) ->
    true;
awaits_response(_State) ->
    false.

% A CON is in transit as long as it has not been acknowledged, rejected, or timed out.
-spec in_transit(exchange()) -> boolean().
in_transit(#exchange{stage=await_pack}) -> 
    true;
in_transit(_State) -> 
    false.

% ->NON
-spec idle({in | out, binary()}, ecoap_endpoint:trans_args(), exchange()) -> exchange().
idle(Msg={in, <<1:2, 1:2, _:12, _Tail/bytes>>}, TransArgs, State) ->
    in_non(Msg, TransArgs, State#exchange{expire_time=native_time(?NON_LIFETIME)});
% ->CON
idle(Msg={in, <<1:2, 0:2, _:12, _Tail/bytes>>}, TransArgs, State) ->
    in_con(Msg, TransArgs, State#exchange{expire_time=native_time(?EXCHANGE_LIFETIME)});
% NON->
idle(Msg={out, #{type:='NON'}}, TransArgs, State) ->
    out_non(Msg, TransArgs, State#exchange{expire_time=native_time(?NON_LIFETIME)});
% CON->
idle(Msg={out, #{type:='CON'}}, TransArgs, State) ->
    out_con(Msg, TransArgs, State#exchange{expire_time=native_time(?EXCHANGE_LIFETIME)}).

% --- incoming NON
-spec in_non({in, binary()}, ecoap_endpoint:trans_args(), exchange()) -> exchange().
in_non({in, BinMessage}, TransArgs, State) ->
    case catch {ok, coap_message:decode(BinMessage)} of
        {ok, #{code := Method} = Message} when is_atom(Method) ->
            handle_request(Message, TransArgs, State),
            check_next_state(got_non, State);
        {ok, Message} ->
            handle_response(Message, TransArgs, State),
            check_next_state(got_non, State);
        % shall we send reset?
        _ -> 
            next_state(undefined, State)
    end.

-spec got_non({in, binary()}, ecoap_endpoint:trans_args(), exchange()) -> exchange().
got_non({in, _Message}, _TransArgs, State) ->
    % ignore retransmission
    next_state(got_non, State).

% --- outgoing NON
-spec out_non({out, coap_message:coap_message()}, ecoap_endpoint:trans_args(), exchange()) -> exchange().
out_non({out, Message}, #{sock:=Socket, sock_module:=SocketModule, ep_id:=EpID}, State) ->
    %io:fwrite("~p send outgoing non msg ~p~n", [self(), Message]),
    BinMessage = coap_message:encode(Message),
    ok = SocketModule:send_datagram(Socket, EpID, BinMessage),
    check_next_state(sent_non, State).

% we may get reset
-spec sent_non({in, binary()}, ecoap_endpoint:trans_args(), exchange()) -> exchange().
sent_non({in, BinMessage}, TransArgs, State)->
    case catch {ok, coap_message:decode(BinMessage)} of
        {ok, #{type := 'RST'} = Rst} ->
            handle_error(Rst, 'RST', TransArgs, State),
            next_state(got_rst, State);
        {ok, _} ->
            next_state(sent_non, State);
        _ -> 
            next_state(sent_non, State)
    end.

-spec got_rst({in, binary()}, ecoap_endpoint:trans_args(), exchange()) -> exchange().
got_rst({in, _BinMessage}, _TransArgs, State)->
    next_state(got_rst, State).

% --- incoming CON->ACK|RST
-spec in_con({in, binary()}, ecoap_endpoint:trans_args(), exchange()) -> exchange().
in_con({in, BinMessage}, TransArgs, State) ->
    case catch {ok, coap_message:decode(BinMessage)} of
        {ok, #{code := undefined, id := MsgId}} ->
            % provoked reset
            go_rst_sent(ecoap_request:rst(MsgId), TransArgs, State);
        {ok, #{code := Method} = Message} when is_atom(Method) ->
            handle_request(Message, TransArgs, State),
            go_await_aack(Message, TransArgs, State);
        {ok, Message} ->
            handle_response(Message, TransArgs, State),
            go_await_aack(Message, TransArgs, State);
        _ ->
            go_rst_sent(ecoap_request:rst(coap_message:get_id(BinMessage)), TransArgs, State)
    end.

-spec go_await_aack(coap_message:coap_message(), ecoap_endpoint:trans_args(), exchange()) -> exchange().
go_await_aack(Message, TransArgs, State) ->
    % we may need to ack the message
    EmptyACK = ecoap_request:ack(Message),
    BinAck = coap_message:encode(EmptyACK),
    next_state(await_aack, TransArgs, State#exchange{msgbin=BinAck}, ?PROCESSING_DELAY).

-spec await_aack({in, binary()} | {timeout, await_aack} | {out, coap_message:coap_message()}, ecoap_endpoint:trans_args(), exchange()) -> exchange().
await_aack({in, _BinMessage}, _TransArgs, State) ->
    % ignore retransmission
    next_state(await_aack, State);

await_aack({timeout, await_aack}, #{sock:=Socket, sock_module:=SocketModule, ep_id:=EpID}, State=#exchange{msgbin=BinAck}) ->
    io:fwrite("~p <- ack [application didn't respond]~n", [self()]),
    ok = SocketModule:send_datagram(Socket, EpID, BinAck),
    check_next_state(pack_sent, State);

await_aack({out, Ack}, TransArgs, State) ->
    % set correct type for a piggybacked response
    Ack2 = case Ack of
        #{type := 'CON'} -> Ack#{type := 'ACK'};
        Else -> Else
    end,
    go_pack_sent(Ack2, TransArgs, State).

-spec go_pack_sent(coap_message:coap_message(), ecoap_endpoint:trans_args(), exchange()) -> exchange().
go_pack_sent(Ack, #{sock:=Socket, sock_module:=SocketModule, ep_id:=EpID}, State) ->
	%io:fwrite("~p send ack msg ~p~n", [self(), Ack]),
    BinAck = coap_message:encode(Ack),
    ok = SocketModule:send_datagram(Socket, EpID, BinAck),
    check_next_state(pack_sent, State#exchange{msgbin=BinAck}).

-spec go_rst_sent(coap_message:coap_message(), ecoap_endpoint:trans_args(), exchange()) -> exchange().
go_rst_sent(RST, #{sock:=Socket, sock_module:=SocketModule, ep_id:=EpID}, State) ->
    BinRST = coap_message:encode(RST),
    ok = SocketModule:send_datagram(Socket, EpID, BinRST),
    next_state(undefined, State).

-spec pack_sent({in, binary()} | {timeout, await_aack}, ecoap_endpoint:trans_args(), exchange()) -> exchange().
pack_sent({in, _BinMessage}, #{sock:=Socket, sock_module:=SocketModule, ep_id:=EpID}, State=#exchange{msgbin=BinAck}) ->
    % retransmit the ack
    ok = SocketModule:send_datagram(Socket, EpID, BinAck),
    next_state(pack_sent, State);
pack_sent({timeout, await_aack}, _TransArgs, State) ->
	% in case the timeout msg was sent before we cancel the timer
	% ignore the msg
	next_state(pack_sent, State).

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
out_con({out, Message}, TransArgs=#{sock:=Socket, sock_module:=SocketModule, ep_id:=EpID}, State) ->
    %io:fwrite("~p send outgoing con msg ~p~n", [self(), Message]),
    BinMessage = coap_message:encode(Message),
    ok = SocketModule:send_datagram(Socket, EpID, BinMessage),
    % _ = rand:seed(exs1024),
    Timeout = ?ACK_TIMEOUT+rand:uniform(?ACK_RANDOM_FACTOR),
    next_state(await_pack, TransArgs, State#exchange{msgbin=BinMessage, retry_time=Timeout, retry_count=0}, Timeout).

% peer ack
-spec await_pack({in, binary()} | {timeout, await_pack}, ecoap_endpoint:trans_args(), exchange()) -> exchange().
await_pack({in, BinAck}, TransArgs, State) ->
    case catch {ok, coap_message:decode(BinAck)} of
        % this is an empty ack for separate response or observe notification
        {ok, #{type := 'ACK', code := undefined} = Ack} ->
            handle_ack(Ack, TransArgs, State),
            % since we can confirm when an outgoing confirmable message
            % has been acknowledged or reset, we can safely clean the msgbin 
            % which won't be used again from this moment
            check_next_state(aack_sent, State#exchange{msgbin= <<>>});
        {ok, #{type := 'RST'} = Rst} ->
            handle_error(Rst, 'RST', TransArgs, State),
            check_next_state(aack_sent, State#exchange{msgbin= <<>>});
        {ok, Ack} ->
            handle_response(Ack, TransArgs, State),
            check_next_state(aack_sent, State#exchange{msgbin= <<>>});
        % shall we inform the receiver the error?
        _ ->
            next_state(await_pack, State)            
    end;
await_pack({timeout, await_pack}, TransArgs=#{sock:=Socket, sock_module:=SocketModule, ep_id:=EpID}, State=#exchange{msgbin=BinMessage, retry_time=Timeout, retry_count=Count}) when Count < ?MAX_RETRANSMIT ->
    % BinMessage = coap_message:encode(Message),
    %io:fwrite("resend msg for ~p time~n", [Count]),
    ok = SocketModule:send_datagram(Socket, EpID, BinMessage),
    Timeout2 = Timeout*2,
    next_state(await_pack, TransArgs, State#exchange{retry_time=Timeout2, retry_count=Count+1}, Timeout2);
await_pack({timeout, await_pack}, TransArgs, State=#exchange{trid={out, MsgId}}) ->
    handle_error(ecoap_request:rst(MsgId), timeout, TransArgs, State),
    check_next_state(aack_sent, State#exchange{msgbin= <<>>}).

-spec aack_sent({in, binary()} | {timeout, await_pack}, ecoap_endpoint:trans_args(), exchange()) -> exchange().
aack_sent({in, _Ack}, _TransArgs, State) ->
    % ignore ack retransmission
    next_state(aack_sent, State);
aack_sent({timeout, await_pack}, _TransArgs, State) ->
	% in case the timeout msg was sent before we cancel the timer
	% ignore the msg
	next_state(aack_sent, State).

-spec cancelled({_, _}, ecoap_endpoint:trans_args(), exchange()) -> exchange().
cancelled({_, _}, _TransArgs, State) ->
    State.

% utility functions
handle_request(Message=#{code := Method, options := Options}, 
    #{ep_id:=EpID, handler_sup:=HdlSupPid, endpoint_pid:=EndpointPid, handler_regs:=HandlerRegs}, #exchange{receiver=undefined}) ->
    %io:fwrite("handle_request called from ~p with ~p~n", [self(), Message]),
    Uri = coap_message:get_option('Uri-Path', Options, []),
    Query = coap_message:get_option('Uri-Query', Options, []),
    case get_handler(HdlSupPid, EndpointPid, {Method, Uri, Query}, HandlerRegs) of
        {ok, Pid} ->
            Pid ! {coap_request, EpID, EndpointPid, undefined, Message},
            ok;
        {error, shutdown} ->
        	{ok, _} = ecoap_endpoint:send(EndpointPid,
                ecoap_request:response({error, 'NotFound'}, Message)),
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

get_handler(SupPid, EndpointPid, HandlerID, HandlerRegs) ->
    case maps:find(HandlerID, HandlerRegs) of
        error ->          
            ecoap_handler_sup:start_handler(SupPid, EndpointPid, HandlerID);
        {ok, Pid} ->
            {ok, Pid}
    end.

request_complete(EndpointPid, #{options := Options}, Receiver) ->
    case coap_message:get_option('Observe', Options) of
        undefined ->
            EndpointPid ! {request_complete, Receiver},
            ok;
        % an observe notification should not remove the request token
        _Else ->
            ok
    end.

% erlang:start_timer(Time, Dest, Msg) -> TimerRef, receive {timeout, TimerRef, Msg}
% erlang:send_after(Time, Dest, Msg) -> TimerRef, receive Msg

native_time(Time) ->
    erlang:convert_time_unit(Time, millisecond, native).

timeout_after(Time, EndpointPid, TrId, Event) ->
    erlang:send_after(Time, EndpointPid, {timeout, TrId, Event}).

cancel_timer(Timer) ->
    erlang:cancel_timer(Timer, [{async, true}, {info, false}]).

% check deduplication flag to decide whether clean up state
-ifdef(NODEDUP).
check_next_state(_, State) -> next_state(undefined, State).
-else.
check_next_state(Stage, State) -> next_state(Stage, State).
-endif.

% start the timer
next_state(Stage, #{endpoint_pid:=EndpointPid}, State=#exchange{trid=TrId, timer=undefined}, Timeout) ->
    Timer = timeout_after(Timeout, EndpointPid, TrId, Stage),
    State#exchange{stage=Stage, timer=Timer};
% restart the timer
next_state(Stage, #{endpoint_pid:=EndpointPid}, State=#exchange{trid=TrId, timer=Timer1}, Timeout) ->
    _ = cancel_timer(Timer1),
    Timer2 = timeout_after(Timeout, EndpointPid, TrId, Stage),
    State#exchange{stage=Stage, timer=Timer2}.

next_state(undefined, #exchange{timer=undefined}) ->
    undefined;
next_state(undefined, #exchange{timer=Timer}) ->
    _ = cancel_timer(Timer),
    undefined;
next_state(Stage, State=#exchange{timer=undefined}) ->
    State#exchange{stage=Stage};
next_state(Stage, State=#exchange{stage=Stage1, timer=Timer}) ->
    if
        % when going to another stage, the timer is cancelled
        Stage /= Stage1 ->
            _ = cancel_timer(Timer),
            State#exchange{stage=Stage, timer=undefined};
        % when staying in current stage, the timer continues
        true ->
            State
    end.

