-module(coap_endpoint).
-behaviour(gen_server).

%% API.
-export([start_link/3, close/1]).

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
-define(SCAN_INTERVAL, 30).

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
    handler_sup = undefined :: pid(),
	tokens = undefined :: map(),
	trans = undefined :: map(),
	nextmid = undefined :: non_neg_integer(),
	rescnt = undefined :: non_neg_integer(),
    timer = undefined :: reference()
}).

-opaque state() :: #state{}.
-export_type([state/0]).

-include("coap.hrl").

%% API.

-spec start_link(pid(), inet:socket(), coap_endpoint_id()) -> {ok, pid()}.
start_link(SupPid, Socket, EpID) ->
	proc_lib:start_link(?MODULE, init, [SupPid, Socket, EpID]).

-spec close(pid()) -> ok.
close(Pid) ->
	gen_server:cast(Pid, shutdown).

%% gen_server.

% Just a placeholder for gen_server behavior
init(_Args) ->
    {ok, _Args}.

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
handle_info({datagram, BinMessage = <<?VERSION:2, 0:1, _:1, _TKL:4, 0:3, _CodeDetail:5, MsgId:16, _/bytes>>}, State = #state{sock=Socket, ep_id=EpID, handler_sup=HdlSupPid, trans = Trans}) ->
	TrId = {in, MsgId},
    % debug
    io:format("HdlSupPid: ~p~n", [HdlSupPid]),
    io:format("incoming CON/NON request, TrId:~p~n", [TrId]),
    io:format("MsgBin: ~p~n", [BinMessage]),
    io:format("Msg: ~p~n", [coap_message:decode(BinMessage)]),
    Data = coap_message:encode(#coap_message{type = 'ACK', code = {ok, 'CONTENT'}, id = MsgId, options = [{'Content-Format', <<"text/plain">>}, {'Accept', 50}], payload = <<"Hello World!">>}),
    {PeerIP, PeerPortNo} = EpID,
    ok = gen_udp:send(Socket, PeerIP, PeerPortNo, Data),
    {noreply, State#state{trans = maps:put(TrId, {erlang:monotonic_time(), BinMessage}, Trans)}};
    % end of debug

% incoming CON(0) or NON(1) response
handle_info({datagram, BinMessage = <<?VERSION:2, 0:1, _:1, TKL:4, _Code:8, MsgId:16, _Token:TKL/bytes, _/bytes>>},
        State = #state{}) ->
	TrId = {in, MsgId},
    % debug
	io:format("incoming CON/NON response, TrId:~p~n", [TrId]),
    io:format("MsgBin: ~p~n", [BinMessage]),
    io:format("Msg: ~p~n", [coap_message:decode(BinMessage)]),
    % end of debug
    {noreply, State};
% incoming ACK(2) or RST(3) to a request or response
handle_info({datagram, BinMessage = <<?VERSION:2, _:2, _TKL:4, _Code:8, MsgId:16, _/bytes>>},
        State = #state{}) ->
    TrId = {out, MsgId},
    % debug
    io:format("incoming ACK/RST to a req/res, TrId:~p~n", [TrId]),
    io:format("MsgBin: ~p~n", [BinMessage]),
    io:format("Msg: ~p~n", [coap_message:decode(BinMessage)]),
    % end of debug
    {noreply, State};
% silently ignore other versions
handle_info({datagram, <<Ver:2, _/bytes>>}, State) when Ver /= ?VERSION ->
    % io:format("unknown CoAP version~n"),
    {noreply, State};
handle_info({timeout, TRef, scan}, State=#state{ep_id = _EpID, timer = TRef, trans = Trans}) ->
    % io:format("coap_endpoint ~p timeout, terminate~n", [EpID]),
    NewTrans = maps:filter(fun(_TrId, {Timestamp, _BinMessage}) -> erlang:convert_time_unit(erlang:monotonic_time() - Timestamp, native, milli_seconds) < 100*1000 end, Trans),
    case maps:size(NewTrans) of
        0 ->
            io:format("All trans expired~n"),
            {stop, normal, State#state{trans = NewTrans}};
        _ ->
            NewTRef = erlang:start_timer(?SCAN_INTERVAL*1000, self(), scan),
            io:format("Ongoing trans exist, start new timer~n"),
            {noreply, State#state{trans = NewTrans, timer = NewTRef}}
    end;
handle_info(_Info, State) ->
    % io:format("unknown info ~p~n", [_Info]),
	{noreply, State}.

-spec terminate(any(), state()) -> ok.
terminate(_Reason, _State) ->
	ok.

-spec code_change(_, _, _) -> {ok, _}.
code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%% Internal
first_mid() ->
    _ = rand:seed(exsplus),
    rand:uniform(?MAX_MESSAGE_ID).

% next_mid(MsgId) ->
%     if
%         MsgId < ?MAX_MESSAGE_ID -> MsgId + 1;
%         true -> 1 % or 0?
%     end.
