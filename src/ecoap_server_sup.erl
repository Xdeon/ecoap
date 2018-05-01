-module(ecoap_server_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).
-export([endpoint_sup_sup/1]).
-export([start_socket/3, stop_socket/2]).

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

start_socket(udp, Name, SocketOpts) ->	
	supervisor:start_child(?MODULE, 
				#{id => Name,
			      start => {ecoap_udp_socket, start_link, [whereis(?MODULE), Name, SocketOpts]},
			      restart => permanent, 
			      shutdown => 10000, 
			      type => worker, 
				  modules => [ecoap_udp_socket]}
	).

stop_socket(udp, Name) ->
	_ = supervisor:terminate_child(?MODULE, Name),
	_ = supervisor:delete_child(?MODULE, Name),
	ok.

endpoint_sup_sup(SupPid) ->
	{_, Pid, _, _} = lists:keyfind(endpoint_sup_sup, 1, supervisor:which_children(SupPid)),
	Pid.