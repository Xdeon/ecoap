-module(endpoint_sup_sup).
-behaviour(supervisor).

-export([start_link/1]).
-export([init/1]).

start_link(MFA = {_,_,_}) ->
	supervisor:start_link({local, ?MODULE}, ?MODULE, MFA).

init({M, F, A}) ->
	MaxRestart = 0,
	MaxTime = 1,
	{ok, 
        {
            #{strategy => simple_one_for_one, 
              intensity => MaxRestart, 
              period => MaxTime}, 
            [
                #{id => endpoint_sup, 
                start => {M, F, A}, 
                restart => temporary, shutdown => infinity, type => supervisor, modules => [M]}
            ]
        }
    }.