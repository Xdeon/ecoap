-module(ecoap_server_sup).
-behaviour(supervisor).

-export([start_link/3]).
-export([init/1]).
-export([find_ecoap_server/2]).
-export([start_endpoint_sup_sup/1]).

-spec start_link(mfa(), atom(), worker | supervisor) -> {ok, pid()} | {error, term()}.
start_link(SocketMFA, Name, Type) ->
	supervisor:start_link(?MODULE, [SocketMFA, Name, Type]).

init([{Module, Fun, Args}, Name, Type]) ->
	Procs = [#{id => Name,
		       start => {Module, Fun, [self()|Args]},
		       restart => permanent, 
		       type => Type, 
			   modules => [Module]}],
	{ok, {#{strategy => one_for_all, intensity => 3, period => 10}, Procs}}.

start_endpoint_sup_sup(SupPid) ->
	Procs = #{id => endpoint_sup_sup,
		       start => {endpoint_sup_sup, start_link, []},
			   restart => permanent,
			   shutdown => infinity,
			   type => supervisor,
   			   modules => [endpoint_sup_sup]},
   	case supervisor:start_child(SupPid, Procs) of
   		{ok, Pid} -> {ok, Pid};
   		{error, {already_started, Pid}} -> {ok, Pid};
   		Other -> Other
   	end. 

find_ecoap_server(SupPid, Name) ->
	find_child(SupPid, Name).

find_child(SupPid, Id) ->
	{_, Pid, _, _} = lists:keyfind(Id, 1, supervisor:which_children(SupPid)),
	Pid.