-module(coap_endpoint).
-behaviour(gen_server).

%% API.
-export([start_link/3, start_link/2, close/1, ping/1, send/2, send_message/3, send_request/3, send_response/3]).

%% gen_server.
-export([init/1]).
-export([init/3]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-define(VERSION, 1).
-define(MAX_MESSAGE_ID, 65535). % 16-bit number
-define(SCAN_INTERVAL, 10).

-define(HDLSUP_SPEC,
    {coap_handler_sup,
    {coap_handler_sup, start_link, []},
    temporary,
    infinity,
    supervisor,
    [coap_handler_sup]}).

-record(state, {
	sock = undefined :: inet:socket(),
	ep_id = undefined :: coap_endpoint_id(),
    handler_sup = undefined :: undefined | pid(),
	tokens = undefined :: map(),
	trans = undefined :: map(),
	nextmid = undefined :: non_neg_integer(),
	rescnt = undefined :: non_neg_integer(),
    timer = undefined :: reference(),
    client = false :: boolean()
}).

-opaque state() :: #state{}.
-export_type([state/0]).

-include("coap.hrl").
-include("coap_exchange.hrl").

%% API.

-spec start_link(pid(), inet:socket(), coap_endpoint_id()) -> {ok, pid()}.
start_link(SupPid, Socket, EpID) ->
	proc_lib:start_link(?MODULE, init, [SupPid, Socket, EpID]).

start_link(Socket, EpID) ->
    gen_server:start_link(?MODULE, [Socket, EpID], []).

-spec close(pid()) -> ok.
close(Pid) ->
	gen_server:cast(Pid, shutdown).

-spec ping(pid()) -> {ok, term()}.
ping(EndpointPid) ->
    send_message(EndpointPid, make_ref(), #coap_message{type='CON'}).

-spec send(pid(), coap_message()) -> {ok, term()}.
send(EndpointPid, Message=#coap_message{type=Type, code=Method})
        when is_tuple(Method); Type=='ACK'; Type=='RST' ->
    send_response(EndpointPid, make_ref(), Message);

send(EndpointPid, Message=#coap_message{}) ->
    send_request(EndpointPid, make_ref(), Message).

-spec send_request(pid(), term(), coap_message()) -> {ok, term()}.
send_request(EndpointPid, Ref, Message) ->
    gen_server:cast(EndpointPid, {send_request, Message, {self(), Ref}}),
    {ok, Ref}.

-spec send_message(pid(), term(), coap_message()) -> {ok, term()}.
send_message(EndpointPid, Ref, Message) ->
    gen_server:cast(EndpointPid, {send_message, Message, {self(), Ref}}),
    {ok, Ref}.

-spec send_response(pid(), term(), coap_message()) -> {ok, term()}.
send_response(EndpointPid, Ref, Message) ->
    gen_server:cast(EndpointPid, {send_response, Message, {self(), Ref}}),
    {ok, Ref}.

%% gen_server.

-spec init(_) -> {ok, #state{}}.
init([Socket, EpID]) ->
    TRef = erlang:start_timer(?SCAN_INTERVAL*1000, self(), scan),
    {ok, #state{sock=Socket, ep_id=EpID, tokens=maps:new(), trans=maps:new(), nextmid=first_mid(), rescnt=0, timer=TRef, client=true}}.

-spec init(pid(), inet:socket(), coap_endpoint_id()) -> no_return().
init(SupPid, Socket, EpID) ->
    ok = proc_lib:init_ack({ok, self()}),
    {ok, Pid} = supervisor:start_child(SupPid, ?HDLSUP_SPEC),
    link(Pid),
    % {ok, TRef} = timer:send_interval(timer:seconds(?SCAN_INTERVAL), self(), {timeout}),
    % timer is slow, use erlang:send_after or erlang:start_timer
    TRef = erlang:start_timer(?SCAN_INTERVAL*1000, self(), scan),
    gen_server:enter_loop(?MODULE, [], #state{sock=Socket, ep_id=EpID, handler_sup=Pid, tokens=maps:new(), trans=maps:new(), nextmid=first_mid(), rescnt=0, timer=TRef}).

-spec handle_call(any(), from(), State) -> {reply, ignored, State} when State :: state().
handle_call(_Request, _From, State) ->
	{reply, ignored, State}.

-spec handle_cast(any(), State) -> {noreply, State} when State :: state().
% outgoing CON(0) or NON(1) request
handle_cast({send_request, Message, Receiver}, State) ->
    make_new_request(Message, Receiver, State);
% outgoing CON(0) or NON(1)
handle_cast({send_message, Message, Receiver}, State) ->
    make_new_message(Message, Receiver, State);
% outgoing response, either CON(0) or NON(1), piggybacked ACK(2) or RST(3)
handle_cast({send_response, Message, Receiver}, State) ->
    make_new_response(Message, Receiver, State);
% When used as client, only stop running after received shutdown msg
handle_cast(shutdown, State) ->
	{stop, normal, State};
handle_cast(_Msg, State) ->
	{noreply, State}.

%% CoAP Message Format
%%
%%  0                   1                   2                   3
%%  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
%% +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%% |Ver| T |  TKL  |      Code     |          Message ID           |
%% +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%% |   Token (if any, TKL bytes) ...                               |
%% +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%% |   Options (if any) ...                                        |
%% +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%% |1 1 1 1 1 1 1 1|    Payload (if any) ...                       |
%% +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%%
%%
-spec handle_info({datagram, binary()}, State) -> {noreply, State};
    ({timeout, reference(), term()}, State) -> {noreply, State} | {stop, normal, State} when State :: state().
% incoming CON(0) or NON(1) request
handle_info({datagram, BinMessage = <<?VERSION:2, 0:1, _:1, _TKL:4, 0:3, _CodeDetail:5, MsgId:16, _/bytes>>}, State = #state{}) ->
	TrId = {in, MsgId},
    % debug
    io:format("incoming CON/NON request, TrId:~p~n", [TrId]),
    io:format("MsgBin: ~p~n", [BinMessage]),
    % end of debug
    update_state(State, TrId,
        coap_exchange:received(BinMessage, create_transport(TrId, undefined, State)));
% incoming CON(0) or NON(1) response
handle_info({datagram, BinMessage = <<?VERSION:2, 0:1, _:1, TKL:4, _Code:8, MsgId:16, Token:TKL/bytes, _/bytes>>},
        State = #state{sock = Socket, trans = Trans, ep_id = {PeerIP, PeerPortNo}, tokens = Tokens}) ->
	TrId = {in, MsgId},
    % debug
	io:format("incoming CON/NON response, TrId:~p~n", [TrId]),
    io:format("MsgBin: ~p~n", [BinMessage]),
    % end of debug
    case maps:find(TrId, Trans) of
        {ok, TrState} ->
            update_state(State, TrId, coap_exchange:received(BinMessage, TrState));
        error ->
             case maps:find(Token, Tokens) of
                {ok, Receiver} ->
                    update_state(State, TrId,
                        coap_exchange:received(BinMessage, init_transport(TrId, Receiver, State)));
                error ->
                    % token was not recognized
                    BinReset = coap_message:encode(#coap_message{type='RST', id=MsgId}),
                    io:format("<- reset~n"),
                    ok = gen_udp:send(Socket, PeerIP, PeerPortNo, BinReset)
            end
    end;
% incoming ACK(2) or RST(3) to a request or response
handle_info({datagram, BinMessage = <<?VERSION:2, _:2, _TKL:4, _Code:8, MsgId:16, _/bytes>>},
        State = #state{trans = Trans}) ->
    TrId = {out, MsgId},
    % debug
    io:format("incoming ACK/RST to a req/res, TrId:~p~n", [TrId]),
    io:format("MsgBin: ~p~n", [BinMessage]),
    % end of debug
    update_state(State, TrId,
        case maps:find(TrId, Trans) of
            error -> 
                %% Code added by wilbur
                io:format("No matching state for TrId: ~p~n", [TrId]),
                %% end
                undefined; % ignore unexpected responses
            {ok, TrState} -> coap_exchange:received(BinMessage, TrState)

        end);
% silently ignore other versions
handle_info({datagram, <<Ver:2, _/bytes>>}, State) when Ver /= ?VERSION ->
    % io:format("unknown CoAP version~n"),
    {noreply, State};
handle_info({timeout, TRef, scan}, State=#state{ep_id = _EpID, timer = TRef, trans = Trans}) ->
    NewTrans = maps:filter(fun(_TrId, #exchange{timestamp = Timestamp, expire_time = ExpireTime} = _TrState) -> 
                                erlang:convert_time_unit(erlang:monotonic_time() - Timestamp, native, milli_seconds) < ExpireTime
                            end,
                            Trans),
    % Because timer will be automatically cancelled if the destination pid exits or is not alive, we can safely start new timer here.
    % io:format("scanning~n"),
    NewTRef = erlang:start_timer(?SCAN_INTERVAL*1000, self(), scan),
    purge_state(State#state{timer = NewTRef, trans = NewTrans});
handle_info({timeout, TrId, Event}, State=#state{trans=Trans}) ->
    %% code added by wilbur
    % io:format("timeout, TrId:~p Event:~p~n", [TrId, Event]),
    %% end
    update_state(State, TrId,
        case maps:find(TrId, Trans) of
            error -> undefined; % ignore unexpected responses
            {ok, TrState} -> coap_exchange:timeout(Event, TrState)
        end);
handle_info({request_complete, Token}, State=#state{tokens=Tokens}) ->
    Tokens2 = maps:remove(Token, Tokens),
    purge_state(State#state{tokens=Tokens2});
handle_info(_Info, State) ->
    io:format("unknown info ~p~n", [_Info]),
	{noreply, State}.

-spec terminate(any(), state()) -> ok.
terminate(_Reason, _State) ->
	ok.

-spec code_change(_, _, _) -> {ok, _}.
code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%% Internal
make_new_request(Message, Receiver, State=#state{tokens=Tokens}) ->
    Token = crypto:strong_rand_bytes(4), % shall be at least 32 random bits
    Tokens2 = maps:put(Token, Receiver, Tokens),
    make_new_message(Message#coap_message{token=Token}, Receiver, State#state{tokens=Tokens2}).

make_new_message(Message, Receiver, State=#state{nextmid=MsgId}) ->
    make_message({out, MsgId}, Message#coap_message{id=MsgId}, Receiver, State#state{nextmid=next_mid(MsgId)}).

make_message(TrId, Message, Receiver, State) ->
    update_state(State, TrId,
        coap_exchange:send(Message, create_transport(TrId, Receiver, State))).

make_new_response(Message=#coap_message{id=MsgId}, Receiver, State=#state{trans=Trans}) ->
    io:format("The response: ~p~n", [Message]),
    case maps:find({in, MsgId}, Trans) of
        {ok, TrState} ->
            %% Note by wilbur: coap_transport:awaits_response is used to 
            %% check if we are in the case that
            %% we received a CON request, have its state stored, but did not send its ACK yet
            case coap_exchange:awaits_response(TrState) of
                true ->
                %% Note by wilbur: we are about to send ACK
                %% By calling coap_transport:send, we make the state change to pack_sent
                    update_state(State, {in, MsgId},
                        coap_exchange:send(Message, TrState));
                false ->
                %% Note by wilbur: otherwise it seems we are about to send a separate response?
                %% This may be caused by exceed PROCESSING_DELAY when generating the response?
                    make_new_message(Message, Receiver, State)
            end;
            %% Note by wilbur: why is the separate response by default a CON msg? 
            %% Because in this implementation a response for CON req uses the same msg type 
            %% until it is modified before being sent as an ACK
        error ->
            %% Note by wilbur: Is this line of code used for dealing with out NON response?
            make_new_message(Message, Receiver, State)
    end.

first_mid() ->
    _ = rand:seed(exsplus),
    rand:uniform(?MAX_MESSAGE_ID).

next_mid(MsgId) ->
    if
        MsgId < ?MAX_MESSAGE_ID -> MsgId + 1;
        true -> 1 % or 0?
    end.

create_transport(TrId, Receiver, State=#state{trans=Trans}) ->
    case maps:find(TrId, Trans) of
        {ok, TrState} -> TrState;
        error -> init_transport(TrId, Receiver, State)
    end.

% init(Socket, EpID, EndpointPid, TrId, HdlSupPid, Receiver) ->

init_transport(TrId, undefined, #state{sock=Socket, ep_id=EpID, handler_sup=HdlSupPid}) ->
    coap_exchange:init(Socket, EpID, self(), TrId, HdlSupPid, undefined);
init_transport(TrId, Receiver, #state{sock=Socket, ep_id=EpID}) ->
    coap_exchange:init(Socket, EpID, self(), TrId, undefined, Receiver).

update_state(State=#state{trans=Trans}, TrId, undefined) ->
    Trans2 = maps:remove(TrId, Trans),
    {noreply, State#state{trans=Trans2}};
update_state(State=#state{trans=Trans}, TrId, TrState) ->
    Trans2 = maps:put(TrId, TrState, Trans),
    {noreply, State#state{trans=Trans2}}.

purge_state(State=#state{tokens=Tokens, trans=Trans, rescnt=Count, client=false}) ->
    case maps:size(Tokens) + maps:size(Trans) + Count of
        0 -> 
            % io:format("All trans expired~n"),
            {stop, normal, State};
        _Else -> 
            % io:format("Ongoing trans exist~n"),
            {noreply, State}
    end;
purge_state(State) ->
    {noreply, State}.
