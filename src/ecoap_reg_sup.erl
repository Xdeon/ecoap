-module(ecoap_reg_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
	supervisor:start_link(?MODULE, []).

init([]) ->
	_ = ets:new(ecoap_registry, [set, named_table, public, {read_concurrency, true}]),
	Procs = [#{id => ecoap_registry,
			   start => {ecoap_registry, start_link, []},
			   restart => permanent,
			   shutdown => 10000,
			   type => worker,
			   modules => [ecoap_registry]}],
	{ok, {#{strategy => one_for_one, intensity => 3, period => 10}, Procs}}.
