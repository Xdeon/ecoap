-module(ecoap_sup).
-behaviour(supervisor).

-export([start_link/1]).
-export([init/1]).


start_link(InPort) ->
	supervisor:start_link({local, ?MODULE}, ?MODULE, [InPort]).

init([InPort]) ->
	Procs = [#{id => ecoap_socket,
			   start => {ecoap_socket, start_link, [self(), InPort]},
			   restart => permanent, 
			   shutdown => 10000, 
		       type => worker, 
			   modules => [ecoap_socket]},
			 #{id => ecoap_reg_sup,
			   start => {ecoap_reg_sup, start_link, []},
			   restart => permanent,
			   shutdown => infinity,
			   type => supervisor,
			   modules => [ecoap_reg_sup]}
    		],
    {ok, {#{strategy => one_for_all, intensity => 3, period => 10}, Procs}}.
