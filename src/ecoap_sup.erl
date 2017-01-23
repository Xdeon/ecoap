-module(ecoap_sup).
-behaviour(supervisor).

-export([start_link/2]).
-export([init/1]).


start_link(InPort, Opts) ->
	supervisor:start_link(?MODULE, [InPort, Opts]).

init([InPort, Opts]) ->
	Procs = [#{id => ecoap_reg_sup,
			   start => {ecoap_reg_sup, start_link, []},
			   restart => permanent,
			   shutdown => infinity,
			   type => supervisor,
			   modules => [ecoap_reg_sup]},
			   #{id => ecoap_socket,
			   start => {ecoap_socket, start_link, [self(), InPort, Opts]},
			   restart => permanent, 
			   shutdown => 10000, 
		       type => worker, 
			   modules => [ecoap_socket]}
    		],
    {ok, {#{strategy => rest_for_one, intensity => 3, period => 10}, Procs}}.
