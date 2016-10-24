-module(coap_exchange).
% -export([]).
-compile([export_all]).

-define(ACK_TIMEOUT, 2000).
-define(ACK_RANDOM_FACTOR, 1000). % ACK_TIMEOUT*0.5
-define(MAX_RETRANSMIT, 4).

-define(PROCESSING_DELAY, 1000). % standard allows 2000
-define(EXCHANGE_LIFETIME, 247000).
% -define(EXCHANGE_LIFETIME, 16000).
% -define(NON_LIFETIME, 145000).
-define(NON_LIFETIME, 100000).

% -record(exchange, {
% 	timestamp = undefined :: non_neg_integer(),
% 	expire_time = undefined :: undefined | non_neg_integer(),
% 	stage = undefined :: atom(),
% 	sock = undefined :: inet:socket(),
% 	ep_id = undefined :: coap_endpoint_id(),
% 	endpoint_pid = undefined :: pid(),
% 	trid = undefined :: {in, non_neg_integer()} | {out, non_neg_integer()},
% 	handler_sup = undefined :: pid(),
% 	receiver = undefined :: undefined | {reference(), pid()},
% 	msgbin = undefined :: undefined | binary(),
% 	timer = undefined :: undefined | reference(),
% 	retry_time = undefined :: undefined | non_neg_integer(),
% 	retry_count = undefined :: undefined | non_neg_integer()
% 	}).

-include("coap.hrl").
-include("coap_exchange.hrl").

% -record(state, {phase, sock, cid, channel, tid, resp, receiver, msg, timer, retry_time, retry_count}).

init(Socket, EpID, EndpointPid, TrId, HdlSupPid, Receiver) ->
    #exchange{timestamp=erlang:monotonic_time(), stage=idle, sock=Socket, ep_id=EpID, endpoint_pid=EndpointPid, trid=TrId, handler_sup=HdlSupPid, receiver=Receiver}.
% process incoming message
received(BinMessage, State=#exchange{stage=Stage}) ->
    ?MODULE:Stage({in, BinMessage}, State).
% process outgoing message
send(Message, State=#exchange{stage=Stage}) ->
    ?MODULE:Stage({out, Message}, State).
% when the transport expires remove terminate the state
% timeout(transport, _State) ->
%     undefined;
% process timeout
timeout(Event, State=#exchange{stage=Stage}) ->
    ?MODULE:Stage({timeout, Event}, State).
% check if we can send a response
awaits_response(#exchange{stage=await_aack}) ->
    true;
awaits_response(_State) ->
    false.

% ->NON
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
% NON(RESPONSE)-> => end
% NON(RESPONSE)-> => ->RST
% As a client:
% NON(REQUEST)-> => ->NON(RESPONSE), token is cleaned up by calling handle_response & request_complete
% NON(REQUEST)-> => ->RST, token is cleaned up by calling handle_error & request_complete
% NON(REQUEST)-> => ->CON(RESPONSE) => ACK(EMPTY)->, token is cleaned up by calling handle_response & request_complete, who sends the ACK?

% --- incoming NON

in_non({in, BinMessage}, State) ->
    case catch coap_message:decode(BinMessage) of
        #coap_message{code = Method} = Message when is_atom(Method) ->
            handle_request(Message, State);
        #coap_message{} = Message ->
            handle_response(Message, State);
        {error, _Error} ->
            % shall we sent reset back?
            ok
    end,
    next_state(got_non, State).
    % undefined.

got_non({in, _Message}, State) ->
    % ignore request retransmission
    next_state(got_non, State).

% --- outgoing NON

out_non({out, Message}, State=#exchange{sock=Socket, ep_id={PeerIP, PeerPortNo}}) ->
    io:fwrite("~p send outgoing non msg ~p~n", [self(), Message]),
    BinMessage = coap_message:encode(Message),
    ok = gen_udp:send(Socket, PeerIP, PeerPortNo, BinMessage),
    next_state(sent_non, State).
    % undefined.

% we may get reset
sent_non({in, BinMessage}, State)->
    case catch coap_message:decode(BinMessage) of
        #coap_message{type='RST'} = Message ->
            handle_error(Message, 'RST', State);
        % in case we get wrong reply, ignore it 
        #coap_message{} -> undefined
    end,
    next_state(got_rst, State).

got_rst({in, _BinMessage}, State)->
    next_state(got_rst, State).


% --- incoming CON->ACK|RST

in_con({in, BinMessage}, State) ->
    case catch coap_message:decode(BinMessage) of
        #coap_message{code=undefined, id=MsgId} ->
            % provoked reset
            go_pack_sent(#coap_message{type='RST', id=MsgId}, State);
        #coap_message{code=Method} = Message when is_atom(Method) ->
            handle_request(Message, State),
            go_await_aack(Message, State);
        #coap_message{} = Message ->
            handle_response(Message, State),
            go_await_aack(Message, State);
        {error, Error} ->
            go_pack_sent(#coap_message{type='ACK', code={error, 'BAD_REQUEST'},
                                       id=coap_message:message_id(BinMessage),
                                       payload=list_to_binary(Error)}, State)
    end.

go_await_aack(Message, State) ->
    % we may need to ack the message
    #coap_message{id = MsgId, token = Token} = Message, 
    EmptyACK = #coap_message{type = 'ACK', id = MsgId, token = Token},
    % BinAck = coap_message:encode(coap_message:response(Message)),
    BinAck = coap_message:encode(EmptyACK),
    next_state(await_aack, State#exchange{msgbin=BinAck}, ?PROCESSING_DELAY).

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

go_pack_sent(Ack, State=#exchange{sock=Socket, ep_id=EpID}) ->
	io:fwrite("~p send ack msg ~p~n", [self(), Ack]),
    BinAck = coap_message:encode(Ack),
    % Sock ! {datagram, ChId, BinAck},
    {PeerIP, PeerPortNo} = EpID,
    ok = gen_udp:send(Socket, PeerIP, PeerPortNo, BinAck),
    next_state(pack_sent, State#exchange{msgbin=BinAck}).
    % undefined.

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
await_pack({in, BinAck}, State) ->
    case catch coap_message:decode(BinAck) of
    	% this is an empty ack for separate response
        #coap_message{type='ACK', code=undefined} = Ack ->
            handle_ack(Ack, State);
        #coap_message{type='RST'} = Ack ->
            handle_error(Ack, 'RST', State);
        #coap_message{} = Ack ->
        	handle_response(Ack, State);
        {error, _Error} ->
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

aack_sent({in, _Ack}, State) ->
    % ignore ack retransmission
    next_state(aack_sent, State);
aack_sent({timeout, await_pack}, State) ->
	% in case the timeout msg was sent before we cancel the timer
	% ignore the msg
	next_state(aack_sent, State).




% utility functions

handle_request(Message, #exchange{sock=_Socket, ep_id=_EpID, endpoint_pid=EndpointPid, receiver=undefined}) ->
    io:fwrite("handle_request called from ~p with ~p~n", [self(), Message]),
	#coap_message{id=MsgId, token=Token, type=Type} = Message,
	{ok, _} = case Type of
		'CON' ->
			Msg = #coap_message{type = 'CON', code = {ok, 'CONTENT'}, id = MsgId, token = Token, options = [{'Content-Format', <<"text/plain">>}, {'Accept', 50}], payload = <<"Hello World!">>},
			coap_endpoint:send(EndpointPid, Msg);
		'NON' ->
			Msg = #coap_message{type = 'NON', code = {ok, 'CONTENT'}, id = MsgId, token = Token, options = [{'Content-Format', <<"text/plain">>}, {'Accept', 50}], payload = <<"Hello World!">>},
			coap_endpoint:send(EndpointPid, Msg)
	end,
    ok;
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

% handle_request(Message, #state{cid=ChId, channel=Channel, resp=ReSup, receiver=undefined}) ->
%     io:fwrite("~p => ~p~n", [self(), Message]),
%     case coap_responder_sup:get_responder(ReSup, Message) of
%         {ok, Pid} ->
%             Pid ! {coap_request, ChId, Channel, undefined, Message},
%             ok;
%         {error, {not_found, _}} ->
%             {ok, _} = coap_channel:send(Channel,
%                 coap_message:response({error, not_found}, Message)),
%             ok
%     end;
% handle_request(Message, #state{cid=ChId, channel=Channel, receiver={Sender, Ref}}) ->
%     io:fwrite("~p => ~p~n", [self(), Message]),
%     Sender ! {coap_request, ChId, Channel, Ref, Message},
%     ok.

% handle_response(Message, #state{cid=ChId, channel=Channel, receiver={Sender, Ref}}) ->
%     io:fwrite("~p -> ~p~n", [self(), Message]),
%     Sender ! {coap_response, ChId, Channel, Ref, Message},
%     request_complete(Channel, Message).

% handle_error(Message, Error, #state{cid=ChId, channel=Channel, receiver={Sender, Ref}}) ->
%     io:fwrite("~p -> ~p~n", [self(), Message]),
%     Sender ! {coap_error, ChId, Channel, Ref, Error},
%     request_complete(Channel, Message).

% handle_ack(Message, #state{cid=ChId, channel=Channel, receiver={Sender, Ref}}) ->
%     io:fwrite("~p -> ~p~n", [self(), Message]),

%     %% Code added by wilbur
%     io:format("handle_ack called with receiver ~p~n", [{Sender, Ref}]),
%     %% end

%     Sender ! {coap_ack, ChId, Channel, Ref},
%     ok.

request_complete(EndpointPid, #coap_message{token=Token, options=Options}) ->
    case proplists:get_value('OBSERVE', Options, []) of
        [] ->
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

