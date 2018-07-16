-module(endpoint_sup).
-behaviour(supervisor).

-export([start_link/1]).
-export([init/1]).
-export([start_handler_sup/1]).

%% Only applies to one time use supervision tree...

start_link(Args) ->
    {ok, SupPid} = supervisor:start_link(?MODULE, []),
    {ok, EpPid} = supervisor:start_child(SupPid,
        #{id => ecoap_endpoint,
          start => {ecoap_endpoint, start_link, [SupPid|Args]},
          restart => temporary, 
          shutdown => 5000, 
          type => worker, 
          modules => [ecoap_endpoint]}),
    {ok, SupPid, EpPid}.

init([]) ->
    % crash of any worker will terminate the supervisor 
    {ok, {#{strategy => one_for_all, intensity => 0, period => 1}, []}}.

start_handler_sup(SupPid) ->
    supervisor:start_child(SupPid, 
        #{id => ecoap_handler_sup,
          start => {ecoap_handler_sup, start_link, []},
          restart => permanent, 
          shutdown => infinity, 
          type => supervisor, 
          modules => [ecoap_handler_sup]}).