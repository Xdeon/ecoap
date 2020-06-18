-module(ecoap_endpoint_sup_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-export([start_endpoint/2, stop_endpoint/2]).

start_link() ->
	supervisor:start_link(?MODULE, []).

init([]) ->
    Procs = [#{id => ecoap_endpoint_sup, 
               start => {ecoap_endpoint_sup, start_link, []}, 
               restart => temporary, shutdown => infinity, type => supervisor, modules => [ecoap_endpoint_sup]}],
	{ok, {#{strategy => simple_one_for_one, intensity => 0, period => 1}, Procs}}.

start_endpoint(SupPid, Args) ->
    supervisor:start_child(SupPid, [Args]).

stop_endpoint(SupPid, EpSupPid) ->
    supervisor:terminate_child(SupPid, EpSupPid).