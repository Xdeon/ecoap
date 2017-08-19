-module(ecoap_server_sup).
-behaviour(supervisor).

-export([start_link/2]).
-export([init/1]).

start_link(InPort, Opts) ->
	supervisor:start_link(?MODULE, [InPort, Opts]).

init([InPort, Opts]) ->
	Procs = [
				#{id => ecoap_udp_socket,
			      start => {ecoap_udp_socket, start_link, [self(), InPort, Opts]},
			      restart => permanent, 
			      shutdown => 10000, 
			      type => worker, 
				  modules => [ecoap_udp_socket]},
				#{id => endpoint_sup_sup,
			      start =>{endpoint_sup_sup, start_link, []},
				  restart => permanent,
				  shutdown => infinity,
				  type => supervisor,
				  modules => [endpoint_sup_sup]}
			],
	{ok, {#{strategy => one_for_all, intensity => 3, period => 10}, Procs}}.
