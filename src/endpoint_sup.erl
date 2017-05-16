-module(endpoint_sup).
-behaviour(supervisor).

-export([start_link/3]).
-export([init/1]).

%% Only applies to one time use supervision tree...

start_link(SocketModule, Socket, EpID) ->
    {ok, SupPid} = supervisor:start_link(?MODULE, []),
    {ok, EpPid} = supervisor:start_child(SupPid,
        #{id => ecoap_endpoint,
         start => {ecoap_endpoint, start_link, [SupPid, SocketModule, Socket, EpID]},
         restart => permanent, 
         shutdown => 5000, 
         type => worker, 
         modules => [ecoap_endpoint]}),
    {ok, SupPid, EpPid}.

init([]) ->
    % crash of any worker will terminate the supervisor and invoke start_link/2 again
    {ok, {#{strategy => one_for_all, intensity => 0, period => 1}, []}}.


