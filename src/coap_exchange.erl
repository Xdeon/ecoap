-module(coap_exchange).

%% API
-export([init/2, received/3, send/3, send_datagram/4, timeout/3, awaits_response/1, not_expired/1]).
-export([idle/3, got_non/3, sent_non/3, got_rst/3, await_aack/3, pack_sent/3, await_pack/3, aack_sent/3]).

-define(ACK_TIMEOUT, 2000).
-define(ACK_RANDOM_FACTOR, 1000). % ACK_TIMEOUT*0.5
-define(MAX_RETRANSMIT, 4).

% -define(PROCESSING_DELAY, 1500). % standard allows 2000
-define(PROCESSING_DELAY, 300000).
% -define(EXCHANGE_LIFETIME, 247000).
-define(EXCHANGE_LIFETIME, 1500).
-define(NON_LIFETIME, 145000).

-record(exchange, {
    timestamp = undefined :: integer(),
    expire_time = undefined :: undefined | non_neg_integer(),
    stage = undefined :: atom(),
    trid = undefined :: coap_endpoint:trid(),
    receiver = undefined :: undefined | coap_endpoint:receiver(),
    msgbin = <<>> :: binary(),
    token = <<>> :: binary(),
    timer = undefined :: undefined | reference(),
    retry_time = undefined :: undefined | non_neg_integer(),
    retry_count = undefined :: undefined | non_neg_integer()
    }).

-type exchange() :: undefined | #exchange{}.

-export_type([exchange/0]).

-include_lib("ecoap_common/include/coap_def.hrl").

% -record(state, {phase, sock, cid, channel, tid, resp, receiver, msg, timer, retry_time, retry_count}).
-spec not_expired(exchange()) -> boolean().
not_expired(#exchange{timestamp=Timestamp, expire_time=ExpireTime}) ->
    erlang:convert_time_unit(erlang:monotonic_time() - Timestamp, native, milli_seconds) < ExpireTime.

-spec init(coap_endpoint:trid(), undefined | coap_endpoint:receiver()) -> exchange().
init(TrId, Receiver) ->
    #exchange{timestamp=erlang:monotonic_time(), stage=idle, trid=TrId, receiver=Receiver}.

% process incoming message
-spec received(binary(), coap_endpoint:trans_args(), exchange()) -> exchange().
received(BinMessage, TransArgs, State=#exchange{stage=Stage}) ->
    ?MODULE:Stage({in, BinMessage}, TransArgs, State).

% process outgoing message
-spec send(coap_message(), coap_endpoint:trans_args(), exchange()) -> exchange().
send(Message, TransArgs, State=#exchange{stage=Stage}) ->
    ?MODULE:Stage({out, Message}, TransArgs, State).

-spec send_datagram(atom(), inet:socket(), ecoap_socket:coap_endpoint_id(), binary()) -> ok.
send_datagram(udp, Socket, {PeerIP, PeerPortNo}, Datagram) ->
    inet_udp:send(Socket, PeerIP, PeerPortNo, Datagram).
% send_datagram(dtls, Socket, _, Datagram) ->
%     ssl:send(Socket, Datagram).

% when the transport expires remove terminate the state
% timeout(transport, _State) ->
%     undefined;
% process timeout
-spec timeout(atom(), coap_endpoint:trans_args(), exchange()) -> exchange().
timeout(Event, TransArgs, State=#exchange{stage=Stage}) ->
    ?MODULE:Stage({timeout, Event}, TransArgs, State).

% check if we can send a response
-spec awaits_response(exchange()) -> boolean().
awaits_response(#exchange{stage=await_aack}) ->
    true;
awaits_response(_State) ->
    false.

% ->NON
-spec idle({in | out, binary()}, coap_endpoint:trans_args(), exchange()) -> exchange().
idle(Msg={in, <<1:2, 1:2, _:12, _Tail/bytes>>}, TransArgs, State=#exchange{}) ->
    % timeout_after(?NON_LIFETIME, Channel, TrId, transport),
    in_non(Msg, TransArgs, State#exchange{expire_time=?NON_LIFETIME});
% ->CON
idle(Msg={in, <<1:2, 0:2, _:12, _Tail/bytes>>}, TransArgs, State=#exchange{}) ->
    % timeout_after(?EXCHANGE_LIFETIME, Channel, TrId, transport),
    in_con(Msg, TransArgs, State#exchange{expire_time=?EXCHANGE_LIFETIME});
% NON->
idle(Msg={out, #coap_message{type='NON'}}, TransArgs, State=#exchange{}) ->
    % timeout_after(?NON_LIFETIME, Channel, TrId, transport),
    out_non(Msg, TransArgs, State#exchange{expire_time=?NON_LIFETIME});
% CON->
idle(Msg={out, #coap_message{type='CON'}}, TransArgs, State=#exchange{}) ->
    % timeout_after(?EXCHANGE_LIFETIME, Channel, TrId, transport),
    out_con(Msg, TransArgs, State#exchange{expire_time=?EXCHANGE_LIFETIME}).


% --- incoming NON
-spec in_non({in, binary()}, coap_endpoint:trans_args(), exchange()) -> exchange().
in_non({in, BinMessage}, TransArgs, State) ->
    case catch coap_message:decode(BinMessage) of
        #coap_message{code = Method} = Message when is_atom(Method) ->
            handle_request(Message, TransArgs, State),
            check_next_state(got_non, State);
        #coap_message{} = Message ->
            handle_response(Message, TransArgs, State),
            check_next_state(got_non, State);
        % shall we send reset?
        {error, _Error} -> undefined
    end.

-spec got_non({in, binary()}, coap_endpoint:trans_args(), exchange()) -> exchange().
got_non({in, _Message}, _TransArgs, State) ->
    % ignore request retransmission
    next_state(got_non, State).

% --- outgoing NON
-spec out_non({out, coap_message()}, coap_endpoint:trans_args(), exchange()) -> exchange().
out_non({out, Message}, #{sock:=Socket, sock_mode:=Mode, ep_id:=EpID}, State) ->
    %io:fwrite("~p send outgoing non msg ~p~n", [self(), Message]),
    BinMessage = coap_message:encode(Message),
    ok = send_datagram(Mode, Socket, EpID, BinMessage),
    check_next_state(sent_non, State#exchange{token=coap_utils:get_token(Message)}).

% we may get reset
-spec sent_non({in, binary()}, coap_endpoint:trans_args(), exchange()) -> exchange().
sent_non({in, BinMessage}, TransArgs, State=#exchange{token=Token})->
    case catch coap_message:decode(BinMessage) of
        #coap_message{type='RST'} = Message ->
            handle_error(coap_utils:set_token(Token, Message), 'RST', TransArgs, State),
            next_state(got_rst, State);
        % ignore other response
        #coap_message{} -> 
            next_state(sent_non, State);
        % encounter format error, ignore the message
        {error, _Error} ->
            next_state(sent_non, State)
    end.

-spec got_rst({in, binary()}, coap_endpoint:trans_args(), exchange()) -> exchange().
got_rst({in, _BinMessage}, _TransArgs, State)->
    next_state(got_rst, State).

% --- incoming CON->ACK|RST
-spec in_con({in, binary()}, coap_endpoint:trans_args(), exchange()) -> exchange().
in_con({in, BinMessage}, TransArgs, State) ->
    case catch coap_message:decode(BinMessage) of
        #coap_message{code=undefined, id=MsgId} ->
            % provoked reset
            go_rst_sent(coap_utils:rst(MsgId), TransArgs, State);
        #coap_message{code=Method} = Message when is_atom(Method) ->
            handle_request(Message, TransArgs, State),
            go_await_aack(Message, TransArgs, State);
        #coap_message{} = Message ->
            handle_response(Message, TransArgs, State),
            go_await_aack(Message, TransArgs, State);
        {error, _Error} ->
            undefined
    end.

-spec go_await_aack(coap_message(), coap_endpoint:trans_args(), exchange()) -> exchange().
go_await_aack(Message, TransArgs, State) ->
    % we may need to ack the message
    EmptyACK = coap_utils:ack(Message),
    BinAck = coap_message:encode(EmptyACK),
    next_state(await_aack, TransArgs, State#exchange{msgbin=BinAck}, ?PROCESSING_DELAY).

-spec await_aack({in, binary()} | {timeout, await_aack} | {out, coap_message()}, coap_endpoint:trans_args(), exchange()) -> exchange().
await_aack({in, _BinMessage}, _TransArgs, State) ->
    % ignore request retransmission
    next_state(await_aack, State);

await_aack({timeout, await_aack}, #{sock:=Socket, sock_mode:=Mode, ep_id:=EpID}, State=#exchange{msgbin=BinAck}) ->
    io:fwrite("~p <- ack [application didn't respond]~n", [self()]),
    ok = send_datagram(Mode, Socket, EpID, BinAck),
    check_next_state(pack_sent, State);

await_aack({out, Ack}, TransArgs, State) ->
    % set correct type for a piggybacked response
    Ack2 = case Ack of
        #coap_message{type='CON'} -> Ack#coap_message{type='ACK'};
        Else -> Else
    end,
    go_pack_sent(Ack2, TransArgs, State).

-spec go_pack_sent(coap_message(), coap_endpoint:trans_args(), exchange()) -> exchange().
go_pack_sent(Ack, #{sock:=Socket, sock_mode:=Mode, ep_id:=EpID}, State) ->
	%io:fwrite("~p send ack msg ~p~n", [self(), Ack]),
    BinAck = coap_message:encode(Ack),
    ok = send_datagram(Mode, Socket, EpID, BinAck),
    check_next_state(pack_sent, State#exchange{msgbin=BinAck}).

-spec go_rst_sent(coap_message(), coap_endpoint:trans_args(), exchange()) -> exchange().
go_rst_sent(RST, #{sock:=Socket, sock_mode:=Mode, ep_id:=EpID}, _State) ->
    BinRST = coap_message:encode(RST),
    ok = send_datagram(Mode, Socket, EpID, BinRST),
    undefined.

-spec pack_sent({in, binary()} | {timeout, await_aack}, coap_endpoint:trans_args(), exchange()) -> exchange().
pack_sent({in, _BinMessage}, #{sock:=Socket, sock_mode:=Mode, ep_id:=EpID}, State=#exchange{msgbin=BinAck}) ->
    % retransmit the ack
    ok = send_datagram(Mode, Socket, EpID, BinAck),
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
-spec out_con({out, coap_message()}, coap_endpoint:trans_args(), exchange()) -> exchange().
out_con({out, Message}, TransArgs=#{sock:=Socket, sock_mode:=Mode, ep_id:=EpID}, State) ->
    %io:fwrite("~p send outgoing con msg ~p~n", [self(), Message]),
    BinMessage = coap_message:encode(Message),
    ok = send_datagram(Mode, Socket, EpID, BinMessage),
    % _ = rand:seed(exs1024),
    Timeout = ?ACK_TIMEOUT+rand:uniform(?ACK_RANDOM_FACTOR),
    next_state(await_pack, TransArgs, State#exchange{msgbin=BinMessage, token=coap_utils:get_token(Message), retry_time=Timeout, retry_count=0}, Timeout).

% peer ack
-spec await_pack({in, binary()} | {timeout, await_pack}, coap_endpoint:trans_args(), exchange()) -> exchange().
await_pack({in, BinAck}, TransArgs, State=#exchange{token=Token}) ->
    case catch coap_message:decode(BinAck) of
    	% this is an empty ack for separate response
        #coap_message{type='ACK', code=undefined} = Ack ->
            handle_ack(Ack, TransArgs, State),
            next_state(undefined, State);
            % next_state(aack_sent, State);
        #coap_message{type='RST'} = Ack ->
            handle_error(coap_utils:set_token(Token, Ack), 'RST', TransArgs, State),
            next_state(undefined, State);
            % next_state(aack_sent, State);
        #coap_message{} = Ack ->
        	handle_response(Ack, TransArgs, State),
            next_state(undefined, State);
            % next_state(aack_sent, State);
        % encounter format error, ignore the message
        % shall we inform the receiver?
        {error, _Error} ->
            next_state(await_pack, State)            
    end;
await_pack({timeout, await_pack}, TransArgs=#{sock:=Socket, sock_mode:=Mode, ep_id:=EpID}, State=#exchange{msgbin=BinMessage, retry_time=Timeout, retry_count=Count}) when Count < ?MAX_RETRANSMIT ->
    % BinMessage = coap_message:encode(Message),
    %io:fwrite("resend msg for ~p time~n", [Count]),
    ok = send_datagram(Mode, Socket, EpID, BinMessage),
    Timeout2 = Timeout*2,
    next_state(await_pack, TransArgs, State#exchange{retry_time=Timeout2, retry_count=Count+1}, Timeout2);
await_pack({timeout, await_pack}, TransArgs, State=#exchange{trid={out, MsgId}, token=Token}) ->
    handle_error(coap_utils:set_token(Token, coap_utils:rst(MsgId)), timeout, TransArgs, State),
    next_state(undefined, State).
    % next_state(aack_sent, State).

-spec aack_sent({in, binary()} | {timeout, await_pack}, coap_endpoint:trans_args(), exchange()) -> exchange().
aack_sent({in, _Ack}, _TransArgs, State) ->
    % ignore ack retransmission
    next_state(aack_sent, State);
aack_sent({timeout, await_pack}, _TransArgs, State) ->
	% in case the timeout msg was sent before we cancel the timer
	% ignore the msg
	next_state(aack_sent, State).

% utility functions

handle_request(Message=#coap_message{code=Method, options=Options}, 
    #{ep_id:=EpID, handler_sup:=HdlSupPid, endpoint_pid:=EndpointPid, handler_regs:=HandlerRegs}, 
    #exchange{receiver=undefined}) ->
    %io:fwrite("handle_request called from ~p with ~p~n", [self(), Message]),
    Uri = coap_utils:get_option('Uri-Path', Options, []),
    Query = coap_utils:get_option('Uri-Query', Options, []),
    case coap_handler_sup:get_handler(HdlSupPid, {Method, Uri, Query}, HandlerRegs) of
        {ok, Pid} ->
            Pid ! {coap_request, EpID, EndpointPid, undefined, Message},
            ok;
        {error, 'NotFound'} ->
        	{ok, _} = coap_endpoint:send(EndpointPid,
                coap_utils:response({error, 'NotFound'}, Message)),
            ok
    end;

handle_request(Message, #{ep_id:=EpID, endpoint_pid:=EndpointPid}, #exchange{receiver={Sender, Ref}}) ->
    %io:fwrite("handle_request called from ~p with ~p~n", [self(), Message]),
    Sender ! {coap_request, EpID, EndpointPid, Ref, Message},
    ok.

handle_response(Message, #{ep_id:=EpID, endpoint_pid:=EndpointPid}, #exchange{receiver={Sender, Ref}}) ->
    %io:fwrite("handle_response called from ~p with ~p~n", [self(), Message]),    
    Sender ! {coap_response, EpID, EndpointPid, Ref, Message},
    request_complete(EndpointPid, Message).

handle_error(Message, Error, #{ep_id:=EpID, endpoint_pid:=EndpointPid}, #exchange{receiver={Sender, Ref}}) ->
	%io:fwrite("handle_error called from ~p with ~p~n", [self(), Message]),
	Sender ! {coap_error, EpID, EndpointPid, Ref, Error},
	request_complete(EndpointPid, Message).

handle_ack(_Message, #{ep_id:=EpID, endpoint_pid:=EndpointPid}, #exchange{receiver={Sender, Ref}}) ->
	%io:fwrite("handle_ack called from ~p with ~p~n", [self(), _Message]),
	Sender ! {coap_ack, EpID, EndpointPid, Ref},
	ok.

request_complete(EndpointPid, #coap_message{token=Token, options=Options}) ->
    case coap_utils:get_option('Observe', Options) of
        undefined ->
            EndpointPid ! {request_complete, Token},
            ok;
        % an observe notification should not remove the request token
        _Else ->
            ok
    end.

% erlang:start_timer(Time, Dest, Msg) -> TimerRef, receive {timeout, TimerRef, Msg}
% erlang:send_after(Time, Dest, Msg) -> TimerRef, receive Msg

timeout_after(Time, EndpointPid, TrId, Event) ->
    erlang:send_after(Time, EndpointPid, {timeout, TrId, Event}).

% check deduplication flag to decide whether clean up state
-ifdef(nodedup).
check_next_state(_, _) -> undefined.
-else.
check_next_state(Stage, State) -> next_state(Stage, State).
-endif.

% start the timer
next_state(Stage, #{endpoint_pid:=EndpointPid}, State=#exchange{trid=TrId, timer=undefined}, Timeout) ->
    Timer = timeout_after(Timeout, EndpointPid, TrId, Stage),
    State#exchange{stage=Stage, timer=Timer};
% restart the timer
next_state(Stage, #{endpoint_pid:=EndpointPid}, State=#exchange{trid=TrId, timer=Timer1}, Timeout) ->
    _ = erlang:cancel_timer(Timer1),
    Timer2 = timeout_after(Timeout, EndpointPid, TrId, Stage),
    State#exchange{stage=Stage, timer=Timer2}.

next_state(undefined, #exchange{timer=undefined}) ->
    undefined;
next_state(undefined, #exchange{timer=Timer}) ->
    _ = erlang:cancel_timer(Timer),
    undefined;
next_state(Stage, State=#exchange{timer=undefined}) ->
    State#exchange{stage=Stage};
next_state(Stage, State=#exchange{stage=Stage1, timer=Timer}) ->
    if
        % when going to another stage, the timer is cancelled
        Stage /= Stage1 ->
            _ = erlang:cancel_timer(Timer),
            State#exchange{stage=Stage, timer=undefined};
        % when staying in current phase, the timer continues
        true ->
            State
    end.

