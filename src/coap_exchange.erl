-module(coap_exchange).
% -export([]).
-compile([export_all]).

-define(ACK_TIMEOUT, 2000).
-define(ACK_RANDOM_FACTOR, 1000). % ACK_TIMEOUT*0.5
-define(MAX_RETRANSMIT, 4).

-define(PROCESSING_DELAY, 1000). % standard allows 2000
-define(EXCHANGE_LIFETIME, 247000).
% -define(EXCHANGE_LIFETIME, 16000).
-define(NON_LIFETIME, 145000).
% -define(NON_LIFETIME, 11000).

-record(exchange, {
	stage = undefined :: atom(),
	sock = undefined :: inet:socket(),
	ep_id = undefined :: coap_endpoint_id(),
	endpoint_pid = undefined :: pid(),
	trid = undefined :: {in, non_neg_integer()} | {out, non_neg_integer()},
	handler_sup = undefined :: pid(),
	receiver = undefined :: undefined | {reference(), pid()},
	msgbin = undefined :: undefined | binary(),
	timer = undefined :: undefined | timer:tref(),
	retry_time = undefined :: undefined | non_neg_integer(),
	retry_count = undefined :: undefined | non_neg_integer()
	}).

-include("coap.hrl").

% -record(state, {phase, sock, cid, channel, tid, resp, receiver, msg, timer, retry_time, retry_count}).

init(Socket, EpID, EndpointPid, TrId, HdlSupPid, Receiver) ->
    #exchange{stage=idle, sock=Socket, ep_id=EpID, endpoint_pid=EndpointPid, trid=TrId, handler_sup=HdlSupPid, receiver=Receiver}.
% process incoming message
received(BinMessage, State=#exchange{stage=Stage}) ->
    ?MODULE:Stage({in, BinMessage}, State).
% process outgoing message
send(Message, State=#exchange{stage=Stage}) ->
    ?MODULE:Stage({out, Message}, State).
% when the transport expires remove terminate the state
timeout(transport, _State) ->
    undefined;
% process timeout
timeout(Event, State=#exchange{stage=Stage}) ->
    ?MODULE:Stage({timeout, Event}, State).
% check if we can send a response
awaits_response(#exchange{stage=await_aack}) ->
    true;
awaits_response(_State) ->
    false.





% --- incoming NON


% --- outgoing NON


% --- incoming CON->ACK|RST


% --- outgoing CON->ACK|RST


% utility functions




