-module(ecoap_socket).
-behaviour(gen_server).

%% API.
-export([start_link/0, start_link/2]).

%% gen_server.
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-record(state, {
	sock = undefined :: any(),
	endpoints = undefined :: coap_endpoints(),
	endpoint_pool = undefined :: undefined | pid()
}).

-opaque state() :: #state{}.
-export_type([state/0]).

-type coap_endpoints() :: map().
-export_type([coap_endpoints/0]).

-define(SPEC(MFA),
    {endpoint_sup_sup,
    {endpoint_sup_sup, start_link, [MFA]},
    temporary,
    10000,
    supervisor,
    [endpoint_sup_sup]}).

%% API.

-spec start_link() -> {ok, pid()}.
-spec start_link(pid(), port()) -> {ok, pid()}.
%% client
start_link() ->
	gen_server:start_link(?MODULE, [0], []).
%% server
start_link(SupPid, InPort) ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [SupPid, InPort], []).

%% gen_server.

-spec init(_) -> {ok, state()}.
init([InPort]) ->
	{ok, Socket} = gen_udp:open(InPort, [binary, {active, false}, {reuseaddr, true}]),
	error_logger:info_msg("coap listen on *:~p~n", [InPort]),
	{ok, #state{sock=Socket, endpoints=maps:new()}};
init([SupPid, InPort]) ->
	self() ! {start_endpoint_supervisor, SupPid, _MFA = {endpoint_sup, start_link, []}},
	init([InPort]).

-type from() :: {pid(), term()}.

-spec handle_call
  	(any(), from(), State) -> {reply, ignored, State} when State :: state().
handle_call(_Request, _From, State) ->
	{reply, ignored, State}.

-spec handle_cast
  	(any(), State) -> {noreply, State} when State :: state().
handle_cast(_Msg, State) ->
	{noreply, State}.

-spec handle_info
	({start_endpoint_supervisor, pid(), {atom(), atom(), atom()}}, State) -> {noreply, State} when State :: state().
handle_info({start_endpoint_supervisor, SupPid, MFA}, State = #state{sock=Socket}) ->
    {ok, Pid} = supervisor:start_child(SupPid, ?SPEC(MFA)),
    link(Pid),
    ok = inet:setopts(Socket, [{active, true}]),
    {noreply, State#state{endpoint_pool = Pid}};
handle_info(_Info, State) ->
	{noreply, State}.

terminate(_Reason, #state{sock=Socket}) ->
	gen_udp:close(Socket),
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.
