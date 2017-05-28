-module(ecoap_handler_sup).
-behaviour(supervisor).

-export([start_link/0, start_handler/2]).
-export([init/1]).

start_link() ->
	supervisor:start_link(?MODULE, []).

init([]) ->
    Procs = [#{id => ecoap_handler,
               start => {ecoap_handler, start_link, []},
               restart => temporary, 
               shutdown => 5000, 
               type => worker, 
               modules => [ecoap_handler]}
            ],
    {ok, {#{strategy => simple_one_for_one, intensity => 0, period => 1}, Procs}}.

start_handler(SupPid, HandlerID) ->
    supervisor:start_child(SupPid, [self(), HandlerID]).
    