-module(endpoint_sup).
-behaviour(supervisor).

-export([start_link/3]).
-export([init/1]).

%% Only applies to one time use supervision tree...

start_link(Socket, EpID, Mode) ->
    {ok, SupPid} = supervisor:start_link(?MODULE, []),
    {ok, HdlSupPid} = supervisor:start_child(SupPid, 
      	#{id => coap_handler_sup,
  		    start => {coap_handler_sup, start_link, []},
  		    restart => permanent, 
          shutdown => infinity, 
          type => supervisor, 
          modules => [coap_handler_sup]}),
    {ok, EpPid} = supervisor:start_child(SupPid,
        #{id => coap_endpoint,
         start => {coap_endpoint, start_link, [HdlSupPid, Socket, EpID, Mode]},
         restart => permanent, 
         shutdown => 5000, 
         type => worker, 
         modules => [coap_endpoint]}),
    {ok, SupPid, EpPid}.

init([]) ->
    % crash of any worker will terminate the supervisor and invoke start_link/2 again
    {ok, {#{strategy => one_for_all, intensity => 0, period => 1}, []}}.


