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
	sup = undefined :: pid(),
	sock = undefined :: any(),
	endpoints = undefined :: coap_endpoints()
}).

-opaque state() :: #state{}.
-export_type([state/0]).

-type coap_endpoints() :: map().
-export_type([coap_endpoints/0]).

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

-spec init([]) -> {ok, state()}.
init([SupPid, InPort]) ->
	{ok, Socket} = gen_udp:open(InPort, [binary, {active, true}, {reuseaddr, true}]),
	error_logger:info_msg("coap listen on *:~p~n", [InPort]),
	{ok, #state{sup=SupPid, sock=Socket, endpoints=maps:new()}}.

handle_call(_Request, _From, State) ->
	{reply, ignored, State}.

handle_cast(_Msg, State) ->
	{noreply, State}.

handle_info(_Info, State) ->
	{noreply, State}.

terminate(_Reason, #state{sock=Socket}) ->
	gen_udp:close(Socket),
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.
