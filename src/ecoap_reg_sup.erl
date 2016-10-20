-module(ecoap_reg_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
	supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
	Procs = [#{id => ecoap_registry,
			   start => {ecoap_registry, start_link, []},
			   restart => permanent,
			   shutdown => 10000,
			   type => worker,
			   modules => [ecoap_registry]}],
	{ok, {#{strategy => one_for_one, intensity => 3, period => 10}, Procs}}.