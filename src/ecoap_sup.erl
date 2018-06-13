-module(ecoap_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
	supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
	Procs = [
				#{id => ecoap_reg_sup,
			      start => {ecoap_reg_sup, start_link, []},
			      restart => permanent,
			      shutdown => infinity,
				  type => supervisor,
				  modules => [ecoap_reg_sup]},
			  	#{id => ecoap_server_sup,
			  	  start => {ecoap_server_sup, start_link, []},
			  	  restart => permanent,
			  	  shutdown => infinity,
			  	  type => supervisor,
			  	  modules => [ecoap_server_sup]}
    		],
    {ok, {#{strategy => rest_for_one, intensity => 1, period => 5}, Procs}}.
