-module(ecoap_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).
-export([start_server/4, stop_server/1]).

start_link() ->
	supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
	_ = ets:new(ecoap_registry, [set, named_table, public, {read_concurrency, true}]),
	Procs = [#{id => ecoap_registry,
			   start => {ecoap_registry, start_link, []},
			   restart => permanent,
			   shutdown => 10000,
			   type => worker,
			   modules => [ecoap_registry]}],
    {ok, {#{strategy => one_for_one, intensity => 3, period => 10}, Procs}}.

start_server(SocketMFA, Name, SocketOpts, Config) ->
	ChildSpec = #{id => Name, 
				  start => {ecoap_server_sup, start_link, [SocketMFA, Name, SocketOpts, Config]},
			  	  restart => permanent,
			  	  shutdown => infinity,
			  	  type => supervisor,
			  	  modules => [ecoap_server_sup]},
	{ok, ServerSupPid} = supervisor:start_child(?MODULE, ChildSpec),
	{ok, ecoap_server_sup:ecoap_server(ServerSupPid, Name)}.

stop_server(Name) -> 
	_ = supervisor:terminate_child(?MODULE, Name),
	_ = supervisor:delete_child(?MODULE, Name),
	ok.