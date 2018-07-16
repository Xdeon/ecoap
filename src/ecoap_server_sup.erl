-module(ecoap_server_sup).
-behaviour(supervisor).

-export([start_link/4]).
-export([init/1]).
-export([endpoint_sup_sup/1, ecoap_server/2]).

start_link(SocketMFA, Name, SocketOpts, Config) ->
	supervisor:start_link(?MODULE, [SocketMFA, Name, SocketOpts, Config]).

init([{Module, Fun, Args}, Name, SocketOpts, Config]) ->
	Procs = [#{id => endpoint_sup_sup,
		       start => {endpoint_sup_sup, start_link, []},
			   restart => permanent,
			   shutdown => infinity,
			   type => supervisor,
			   modules => [endpoint_sup_sup]},
			 #{id => Name,
		       start => {Module, Fun, [self(), Name, SocketOpts, Config] ++ Args},
		       restart => permanent, 
		       shutdown => 10000, 
		       type => worker, 
			   modules => [ecoap_udp_socket]}],
	{ok, {#{strategy => one_for_all, intensity => 3, period => 10}, Procs}}.

endpoint_sup_sup(SupPid) ->
	find_child(SupPid, endpoint_sup_sup).

ecoap_server(SupPid, Name) ->
	find_child(SupPid, Name).

find_child(SupPid, Id) ->
	{_, Pid, _, _} = lists:keyfind(Id, 1, supervisor:which_children(SupPid)),
	Pid.