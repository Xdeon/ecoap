-module(ecoap_server_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).
-export([start_socket/2, stop_socket/1]).

start_link() ->
	supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
	Procs = [#{id => endpoint_sup_sup,
		      start =>{endpoint_sup_sup, start_link, []},
			  restart => permanent,
			  shutdown => infinity,
			  type => supervisor,
			  modules => [endpoint_sup_sup]}],
	{ok, {#{strategy => one_for_all, intensity => 3, period => 10}, Procs}}.

start_socket(udp, SocketOpts) ->	
	supervisor:start_child(?MODULE, 
				#{id => ecoap_udp_socket,
			      start => {ecoap_udp_socket, start_link, [whereis(?MODULE), SocketOpts]},
			      restart => permanent, 
			      shutdown => 10000, 
			      type => worker, 
				  modules => [ecoap_udp_socket]}
	).

stop_socket(udp) ->
	_ = supervisor:terminate_child(?MODULE, ecoap_udp_socket),
	_ = supervisor:delete_child(?MODULE, ecoap_udp_socket),
	ok.