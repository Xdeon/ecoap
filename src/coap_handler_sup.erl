-module(coap_handler_sup).
-behaviour(supervisor).

-export([start_link/0, get_handler/4]).
-export([init/1]).

start_link() ->
	supervisor:start_link(?MODULE, []).

init([]) ->
	Procs = [],
	{ok, {{one_for_one, 1, 5}, Procs}}.

get_handler(EndpointPid, SupPid, HandlerID, Observable) ->
    case start_handler(SupPid, HandlerID) of
        {ok, Pid} -> 
            ok = obs_handler_notify(EndpointPid, Observable, Pid),
        	{ok, Pid};
        {error, {already_started, Pid}} -> 
            %% Code added by wilbur
            %ioformat("handler already_started~n"),
            %% end
            {ok, Pid};
        {error, Other} -> {error, Other}
    end.

start_handler(SupPid, HandlerID = {_, Uri, Query}) ->
    %% Code added by wilbur
    %ioformat("start handler for ~p~n", [HandlerID]),
    %% end
    supervisor:start_child(SupPid,
        {HandlerID,
            {coap_handler, start_link, [self(), Uri, Query]},
            temporary, 5000, worker, []}).

obs_handler_notify(EndpointPid, Observable, Pid) ->
    case Observable of
        undefined -> ok;
        _Else ->  EndpointPid ! {obs_handler_started, Pid}, ok
    end.