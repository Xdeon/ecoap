-module(ecoap_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).
-export([start_server/3, stop_server/1]).

start_link() ->
	supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
	_ = ets:new(ecoap_registry, [set, named_table, public, {read_concurrency, true}]),
	Procs = [#{id => ecoap_registry,
			   start => {ecoap_registry, start_link, []},
			   restart => permanent,
			   shutdown => 5000,
			   type => worker,
			   modules => [ecoap_registry]}],
    {ok, {#{strategy => one_for_one, intensity => 3, period => 10}, Procs}}.

start_server(SocketMFA, Name, Type) ->
	Procs = #{id => {ecoap_server_sup, Name}, 
				  start => {ecoap_server_sup, start_link, [SocketMFA, Name, Type]},
			  	  restart => permanent,
			  	  shutdown => infinity,
			  	  type => supervisor,
			  	  modules => [ecoap_server_sup]},
	% case supervisor:start_child(?MODULE, Procs) of
	% 	{ok, ServerSupPid} -> {ok, ecoap_server_sup:find_ecoap_server(ServerSupPid, Name)};
	% 	{error, {already_started, ServerSupPid}} -> {error, {already_started, ecoap_server_sup:find_ecoap_server(ServerSupPid, Name)}};
	% 	{error, Other} -> {error, Other}
	% end.
	supervisor:start_child(?MODULE, Procs).
	
stop_server(Name) -> 
	_ = supervisor:terminate_child(?MODULE, {ecoap_server_sup, Name}),
	_ = supervisor:delete_child(?MODULE, {ecoap_server_sup, Name}),
	ok.