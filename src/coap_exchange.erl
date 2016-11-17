-module(coap_exchange).

-export([init/6, received/2, send/2, timeout/2, awaits_response/1, time_info/1]).
-export([idle/2, got_non/2, sent_non/2, got_rst/2, await_aack/2, pack_sent/2, await_pack/2, aack_sent/2]).

-define(ACK_TIMEOUT, 2000).
-define(ACK_RANDOM_FACTOR, 1000). % ACK_TIMEOUT*0.5
-define(MAX_RETRANSMIT, 4).

-define(PROCESSING_DELAY, 1000). % standard allows 2000
-define(EXCHANGE_LIFETIME, 247000).
% -define(EXCHANGE_LIFETIME, 16000).
-define(NON_LIFETIME, 145000).
% -define(NON_LIFETIME, 100000).

-record(exchange, {
    timestamp = undefined :: non_neg_integer(),
    expire_time = undefined :: undefined | non_neg_integer(),
    stage = undefined :: atom(),
    sock = undefined :: inet:socket(),
    ep_id = undefined :: coap_endpoint_id(),
    endpoint_pid = undefined :: pid(),
    trid = undefined :: trid(),
    handler_sup = undefined :: undefined | pid(),
    receiver = undefined :: receiver(),
    msgbin = undefined :: undefined | binary(),
    timer = undefined :: undefined | reference(),
    retry_time = undefined :: undefined | non_neg_integer(),
    retry_count = undefined :: undefined | non_neg_integer()
    }).

-type exchange() :: #exchange{} | undefined.
-type coap_endpoint_id() :: ecoap_socket:coap_endpoint_id().
-type receiver() :: coap_endpoint:receiver().
-type trid() :: coap_endpoint:trid().

-export_type([exchange/0]).

-include("coap_def.hrl").

% -record(state, {phase, sock, cid, channel, tid, resp, receiver, msg, timer, retry_time, retry_count}).
-spec time_info(exchange()) -> {integer(), non_neg_integer()}.
time_info(#exchange{timestamp=Timestamp, expire_time=ExpireTime}) ->
    {Timestamp, ExpireTime}.

-spec init(inet:socket(), coap_endpoint_id(), pid(), trid(), pid(), receiver()) -> exchange().
init(Socket, EpID, EndpointPid, TrId, HdlSupPid, Receiver) ->
    #exchange{timestamp=erlang:monotonic_time(), stage=idle, sock=Socket, ep_id=EpID, endpoint_pid=EndpointPid, trid=TrId, handler_sup=HdlSupPid, receiver=Receiver}.
% process incoming message
-spec received(binary(), exchange()) -> exchange().
received(BinMessage, State=#exchange{stage=Stage}) ->
    ?MODULE:Stage({in, BinMessage}, State).
% process outgoing message
-spec send(coap_message(), exchange()) -> exchange().
send(Message, State=#exchange{stage=Stage}) ->
    ?MODULE:Stage({out, Message}, State).
% when the transport expires remove terminate the state
% timeout(transport, _State) ->
%     undefined;
% process timeout
-spec timeout(atom(), exchange()) -> exchange().
timeout(Event, State=#exchange{stage=Stage}) ->
    ?MODULE:Stage({timeout, Event}, State).
% check if we can send a response
-spec awaits_response(exchange()) -> boolean().
awaits_response(#exchange{stage=await_aack}) ->
    true;
awaits_response(_State) ->
    false.

% ->NON
-spec idle({in | out, binary()}, exchange()) -> exchange().
idle(Msg={in, <<1:2, 1:2, _:12, _Tail/bytes>>}, State=#exchange{endpoint_pid=_EndpointPid, trid=_TrId}) ->
    % timeout_after(?NON_LIFETIME, Channel, TrId, transport),
    in_non(Msg, State#exchange{expire_time=?NON_LIFETIME});
% ->CON
idle(Msg={in, <<1:2, 0:2, _:12, _Tail/bytes>>}, State=#exchange{endpoint_pid=_EndpointPid, trid=_TrId}) ->
    % timeout_after(?EXCHANGE_LIFETIME, Channel, TrId, transport),
    in_con(Msg, State#exchange{expire_time=?EXCHANGE_LIFETIME});
% NON->
idle(Msg={out, #coap_message{type='NON'}}, State=#exchange{endpoint_pid=_EndpointPid, trid=_TrId}) ->
    % timeout_after(?NON_LIFETIME, Channel, TrId, transport),
    out_non(Msg, State#exchange{expire_time=?NON_LIFETIME});
% CON->
idle(Msg={out, #coap_message{type='CON'}}, State=#exchange{endpoint_pid=_EndpointPid, trid=_TrId}) ->
    % timeout_after(?EXCHANGE_LIFETIME, Channel, TrId, transport),
    out_con(Msg, State#exchange{expire_time=?EXCHANGE_LIFETIME}).


%% For Non-confirmable message %%
% As a server:
% -> NON(REQUEST) => NON(RESPONSE)-> => end
% -> NON(REQUEST) => NON(RESPONSE)-> => ->RST
% As a client:
% NON(REQUEST)-> => ->NON(RESPONSE), token is cleaned up by calling handle_response & request_complete
% NON(REQUEST)-> => ->RST, token is cleaned up by calling handle_error & request_complete
% NON(REQUEST)-> => ->CON(RESPONSE) => ACK(EMPTY)->, token is cleaned up by calling handle_response & request_complete, who sends the ACK?

% New Note: shoule we remove exchange state after receiving empty ACK/RST?

% --- incoming NON
-spec in_non({in, binary()}, exchange()) -> exchange().
in_non({in, BinMessage}, State) ->
    try coap_message:decode(BinMessage) of
        #coap_message{code = Method} = Message when is_atom(Method) ->
            handle_request(Message, State);
        #coap_message{} = Message ->
            handle_response(Message, State)
    catch throw:{error, _Error} -> 
        % shall we sent reset back?
        ok 
    end,  
    next_state(got_non, State).
    % undefined.

-spec got_non({in, binary()}, exchange()) -> exchange().
got_non({in, _Message}, State) ->
    % ignore request retransmission
    next_state(got_non, State).

% --- outgoing NON
-spec out_non({out, coap_message()}, exchange()) -> exchange().
out_non({out, Message}, State=#exchange{sock=Socket, ep_id={PeerIP, PeerPortNo}}) ->
    io:fwrite("~p send outgoing non msg ~p~n", [self(), Message]),
    BinMessage = coap_message:encode(Message),
    ok = gen_udp:send(Socket, PeerIP, PeerPortNo, BinMessage),
    next_state(sent_non, State).
    % undefined.

% we may get reset
-spec sent_non({in, binary()}, exchange()) -> exchange().
sent_non({in, BinMessage}, State)->
    try coap_message:decode(BinMessage) of
        #coap_message{type='RST'} = Message ->
            handle_error(Message, 'RST', State);
        % in case we get wrong reply, ignore it 
        #coap_message{} -> ok
    catch throw:{error, _Error} -> 
        ok 
    end,
    next_state(got_rst, State).

-spec got_rst({in, binary()}, exchange()) -> exchange().
got_rst({in, _BinMessage}, State)->
    next_state(got_rst, State).

% --- incoming CON->ACK|RST
-spec in_con({in, binary()}, exchange()) -> exchange().
in_con({in, BinMessage}, State) ->
    try coap_message:decode(BinMessage) of
        #coap_message{code=undefined, id=MsgId} ->
            % provoked reset
            go_pack_sent(#coap_message{type='RST', id=MsgId}, State);
        #coap_message{code=Method} = Message when is_atom(Method) ->
            handle_request(Message, State),
            go_await_aack(Message, State);
        #coap_message{} = Message ->
            handle_response(Message, State),
            go_await_aack(Message, State)
    catch throw:{error, Error} ->
        go_pack_sent(#coap_message{type='ACK', code={error, 'BadRequest'},
                                       id=coap_message_utils:msg_id(BinMessage),
                                       payload=list_to_binary(Error)}, State)
    end.

-spec go_await_aack(coap_message(), exchange()) -> exchange().
go_await_aack(Message, State) ->
    % we may need to ack the message
    #coap_message{id = MsgId, token = Token} = Message, 
    EmptyACK = #coap_message{type = 'ACK', id = MsgId, token = Token},
    % BinAck = coap_message:encode(coap_message:response(Message)),
    BinAck = coap_message:encode(EmptyACK),
    next_state(await_aack, State#exchange{msgbin=BinAck}, ?PROCESSING_DELAY).

-spec await_aack({in, binary()} | {timeout, await_aack} | {out, coap_message()}, exchange()) -> exchange().
await_aack({in, _BinMessage}, State) ->
    % ignore request retransmission
    next_state(await_aack, State);
await_aack({timeout, await_aack}, State=#exchange{sock=Socket, ep_id={PeerIP, PeerPortNo}, msgbin=BinAck}) ->
    io:fwrite("~p <- ack [application didn't respond]~n", [self()]),
    % Sock ! {datagram, ChId, BinAck},
    ok = gen_udp:send(Socket, PeerIP, PeerPortNo, BinAck),
    next_state(pack_sent, State);

await_aack({out, Ack}, State) ->
    % set correct type for a piggybacked response
    Ack2 = case Ack of
        #coap_message{type='CON'} -> Ack#coap_message{type='ACK'};
        Else -> Else
    end,
    go_pack_sent(Ack2, State).

-spec go_pack_sent(coap_message(), exchange()) -> exchange().
go_pack_sent(Ack, State=#exchange{sock=Socket, ep_id=EpID}) ->
	io:fwrite("~p send ack msg ~p~n", [self(), Ack]),
    BinAck = coap_message:encode(Ack),
    % Sock ! {datagram, ChId, BinAck},
    {PeerIP, PeerPortNo} = EpID,
    ok = gen_udp:send(Socket, PeerIP, PeerPortNo, BinAck),
    next_state(pack_sent, State#exchange{msgbin=BinAck}).
    % undefined.

-spec pack_sent({in, binary()} | {timeout, await_aack}, exchange()) -> exchange().
pack_sent({in, _BinMessage}, State=#exchange{sock=Socket, ep_id={PeerIP, PeerPortNo}, msgbin=BinAck}) ->
    % retransmit the ack
    % Sock ! {datagram, ChId, BinAck},
    ok = gen_udp:send(Socket, PeerIP, PeerPortNo, BinAck),
    next_state(pack_sent, State);
pack_sent({timeout, await_aack}, State) ->
	% in case the timeout msg was sent before we cancel the timer
	% ignore the msg
	next_state(pack_sent, State).


%% For confirmable message %%
% As a server:
% ->CON(REQUEST) => ACK(RESPONSE)->
% ->CON(REQUEST) => ACK(EMPTY)-> => CON(RESPONSE)-> => ->ACK(EMPTY) 
% ->CON(REQUEST) => RST->
% As a client:
% CON(REQUEST)-> => ->RST, token is cleaned up by calling handle_error & request_complete
% CON(REQUEST)-> => ->ACK(RESPONSE), token is cleaned up by calling handle_response & request_complete
% CON(REQUEST)-> => ->ACK(EMPTY) => ->CON(RESPONSE) => ACK(EMPTY)->, token is cleaned up by calling handle_response & request_complete, ??what about the empty ACK??
% CON(REQUEST)-> => ->ACK(EMPTY) => ->NON(RESPONSE), token is cleaned up by calling handle_response & request_complete
% CON(REQUEST)-> => ->CON(RESPONSE) => ACK(EMPTY)-> .... => ->ACK(EMPTY) ignore out of order empty ack form server, token cleaned up by calling handle_response & request_complete

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

% --- outgoing CON->ACK|RST
-spec out_con({out, coap_message()}, exchange()) -> exchange().
out_con({out, Message}, State=#exchange{sock=Socket, ep_id={PeerIP, PeerPortNo}}) ->
    io:fwrite("~p send outgoing con msg ~p~n", [self(), Message]),
    BinMessage = coap_message:encode(Message),
    % Sock ! {datagram, ChId, BinMessage},
    ok = gen_udp:send(Socket, PeerIP, PeerPortNo, BinMessage),
    %_ = random:seed(os:timestamp()),
    _ = rand:seed(exsplus),
    Timeout = ?ACK_TIMEOUT+rand:uniform(?ACK_RANDOM_FACTOR),
    next_state(await_pack, State#exchange{msgbin=BinMessage, retry_time=Timeout, retry_count=0}, Timeout).

% peer ack
-spec await_pack({in, binary()} | {timeout, await_pack}, exchange()) -> exchange().
await_pack({in, BinAck}, State) ->
    try coap_message:decode(BinAck) of
    	% this is an empty ack for separate response
        #coap_message{type='ACK', code=undefined} = Ack ->
            handle_ack(Ack, State);
        #coap_message{type='RST'} = Ack ->
            handle_error(Ack, 'RST', State);
        #coap_message{} = Ack ->
        	handle_response(Ack, State)
    catch throw:{error, _Error} -> 
        % shall we inform the receiver?
        ok 
    end,  
    next_state(aack_sent, State);
await_pack({timeout, await_pack}, State=#exchange{sock=Socket, ep_id={PeerIP, PeerPortNo}, msgbin=BinMessage, retry_time=Timeout, retry_count=Count}) when Count < ?MAX_RETRANSMIT ->
    % BinMessage = coap_message:encode(Message),
    % Sock ! {datagram, ChId, BinMessage},
    io:fwrite("resend msg for ~p time~n", [Count]),
    % erlang:display("I am sending on remote node~n"),
    ok = gen_udp:send(Socket, PeerIP, PeerPortNo, BinMessage),
    Timeout2 = Timeout*2,
    next_state(await_pack, State#exchange{retry_time=Timeout2, retry_count=Count+1}, Timeout2);
await_pack({timeout, await_pack}, State=#exchange{trid={out, _MsgId}, msgbin=BinMessage}) ->
    handle_error(coap_message:decode(BinMessage), timeout, State),
    next_state(aack_sent, State).

-spec aack_sent({in, binary()} | {timeout, await_pack}, exchange()) -> exchange().
aack_sent({in, _Ack}, State) ->
    % ignore ack retransmission
    next_state(aack_sent, State);
aack_sent({timeout, await_pack}, State) ->
	% in case the timeout msg was sent before we cancel the timer
	% ignore the msg
	next_state(aack_sent, State).

% utility functions

handle_request(Message=#coap_message{code=Method, options=Options}, #exchange{ep_id=EpID, endpoint_pid=EndpointPid, handler_sup=HdlSupPid, receiver=undefined}) ->
    io:fwrite("handle_request called from ~p with ~p~n", [self(), Message]),
    Uri = coap_message_utils:get_option('Uri-Path', Options, []),
    Query = coap_message_utils:get_option('Uri-Query', Options, []),
    Observable = coap_message_utils:get_option('Observe', Options),
    case coap_handler_sup:get_handler(EndpointPid, HdlSupPid, {Method, Uri, Query}, Observable) of
        {ok, Pid} ->
            Pid ! {coap_request, EpID, EndpointPid, undefined, Message},
            ok;
        {error, {'NotFound', _}} ->
        	io:format("handler not_found~n"),
        	{ok, _} = coap_endpoint:send(EndpointPid,
                coap_message_utils:response({error, 'NotFound'}, Message)),
            ok
    end;

handle_request(Message, #exchange{ep_id=EpID, endpoint_pid=EndpointPid, receiver={Sender, Ref}}) ->
    io:fwrite("handle_request called from ~p with ~p~n", [self(), Message]),
    Sender ! {coap_request, EpID, EndpointPid, Ref, Message},
    ok.

handle_response(Message, #exchange{ep_id = EpID, endpoint_pid = EndpointPid, receiver = {Sender, Ref}}) ->
    io:fwrite("handle_response called from ~p with ~p~n", [self(), Message]),
	Sender ! {coap_response, EpID, EndpointPid, Ref, Message},
	request_complete(EndpointPid, Message).

handle_error(Message, Error, #exchange{ep_id = EpID, endpoint_pid = EndpointPid, receiver = {Sender, Ref}}) ->
	io:fwrite("handle_error called from ~p with ~p~n", [self(), Message]),
	Sender ! {coap_error, EpID, EndpointPid, Ref, Error},
	request_complete(EndpointPid, Message).

handle_ack(_Message, #exchange{ep_id = EpID, endpoint_pid = EndpointPid, receiver = {Sender, Ref}}) ->
	io:fwrite("handle_ack called from ~p with ~p~n", [self(), _Message]),
	Sender ! {coap_ack, EpID, EndpointPid, Ref},
	ok.

request_complete(EndpointPid, #coap_message{token=Token, options=Options}) ->
    case coap_message_utils:get_option('Observe', Options) of
        undefined ->
            EndpointPid ! {request_complete, Token},
            ok;
        _Else ->
            ok
    end.


% erlang:start_timer(Time, Dest, Msg) -> TimerRef, receive {timeout, TimerRef, Msg}
% erlang:send_after(Time, Dest, Msg) -> TimerRef, receive Msg

timeout_after(Time, EndpointPid, TrId, Event) ->
    erlang:send_after(Time, EndpointPid, {timeout, TrId, Event}).

% start the timer
next_state(Stage, State=#exchange{endpoint_pid=EndpointPid, trid=TrId, timer=undefined}, Timeout) ->
    Timer = timeout_after(Timeout, EndpointPid, TrId, Stage),
    State#exchange{stage=Stage, timer=Timer};
% restart the timer
next_state(Stage, State=#exchange{endpoint_pid=EndpointPid, trid=TrId, timer=Timer1}, Timeout) ->
    _ = erlang:cancel_timer(Timer1),
    Timer2 = timeout_after(Timeout, EndpointPid, TrId, Stage),
    State#exchange{stage=Stage, timer=Timer2}.

next_state(undefined, _State=#exchange{timer=undefined}) ->
    undefined;
next_state(undefined, _State=#exchange{timer=Timer}) ->
    _ = erlang:cancel_timer(Timer),
    undefined;
next_state(Stage, State=#exchange{timer=undefined}) ->
    State#exchange{stage=Stage};
next_state(Stage, State=#exchange{stage=Stage1, timer=Timer}) ->
    if
        % when going to another stage, the timer is cancelled
        Stage /= Stage1 ->
            _ = erlang:cancel_timer(Timer),
            ok;
        % when staying in current phase, the timer continues
        true ->
            ok
    end,
    State#exchange{stage=Stage, timer=undefined}.
