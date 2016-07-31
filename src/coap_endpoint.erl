-module(coap_endpoint).
-behaviour(gen_server).

%% API.
-export([start_link/3, close/1]).

%% gen_server.
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-define(VERSION, 1).
-define(MAX_MESSAGE_ID, 65535). % 16-bit number
-define(HANDLER_SUP_SPEC,
    {coap_handler_sup,
    {coap_handler_sup, start_link, []},
    temporary,
    infinity,
    supervisor,
    [coap_handler_sup]}).

-record(state, {
	sock = undefined :: any(),
	ep_id = undefined :: {_, _},
	tokens = undefined :: map(),
	trans = undefined :: map(),
	nextmid = undefined :: integer(),
	handler_sup = undefined :: undefined | pid(),
	rescnt = undefined :: integer()
}).

-opaque state() :: #state{}.
-export_type([state/0]).

%% API.

-spec start_link(pid(), port(), {_, _}) -> {ok, pid()}.
start_link(SupPid, Socket, EpID) ->
	gen_server:start_link(?MODULE, [SupPid, Socket, EpID], []).

-spec close(pid()) -> ok.
close(Pid) ->
	gen_server:cast(Pid, shutdown).

%% gen_server.

-spec init(_) -> {ok, state()}.
init([SupPid, Socket, EpID]) ->
	self() ! {start_handler_sup, SupPid},
	{ok, #state{sock=Socket, ep_id=EpID, tokens=maps:new(),
        trans=maps:new(), nextmid=first_mid(), rescnt=0}}.

handle_call(_Request, _From, State) ->
	{reply, ignored, State}.

handle_cast(shutdown, State) ->
	{stop, normal, State};
handle_cast(_Msg, State) ->
	{noreply, State}.

handle_info({start_handler_sup, SupPid}, State=#state{}) ->
    {ok, Pid} = supervisor:start_child(SupPid, ?HANDLER_SUP_SPEC),
    link(Pid),
    {noreply, State#state{handler_sup = Pid}};
handle_info({datagram, _BinMessage= <<?VERSION:2, 0:1, _:1, _TKL:4, 0:3, _CodeDetail:5, MsgId:16, _/bytes>>}, State=#state{}) ->
	TrId = {in, MsgId},
    io:format("incoming CON/NON request, TrId:~p~n", [TrId]),
    {noreply, State};
handle_info(_Info, State) ->
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.

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
