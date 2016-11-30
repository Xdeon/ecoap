-module(endpoint_sup_sup).
-behaviour(supervisor).

-export([start_link/1]).
-export([init/1]).

-export([start_endpoint/2, delete_endpoint/2]).

start_link(MFA = {_,_,_}) ->
	supervisor:start_link(?MODULE, MFA).

init({M, F, A}) ->
    Procs = [#{id => endpoint_sup, 
               start => {M, F, A}, 
               restart => temporary, shutdown => infinity, type => supervisor, modules => [M]}],
	{ok, {#{strategy => simple_one_for_one, intensity => 0, period => 1}, Procs}}.

start_endpoint(SupPid, Args) ->
    supervisor:start_child(SupPid, Args).

delete_endpoint(SupPid, EpSupPid) ->
    supervisor:terminate_child(SupPid, EpSupPid).
