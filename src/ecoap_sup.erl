-module(ecoap_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-define(DEFAULT_COAP_PORT, 5683).

start_link() ->
	supervisor:start_link({local, ?MODULE}, ?MODULE, [?DEFAULT_COAP_PORT]).

init([InPort]) ->
	Procs = [#{	id => ecoap_socket,
    			start => {ecoap_socket, start_link, [self(), InPort]},
    			restart => permanent, 
    			shutdown => 10000, 
    			type => worker, 
    			modules => [ecoap_socket]}
    		],
	{ok, {{one_for_all, 3, 10}, Procs}}.
