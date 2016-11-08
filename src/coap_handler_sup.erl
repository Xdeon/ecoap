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
            case Observable of
                [] -> ok;
                _Else ->  EndpointPid ! {obs_handler_started, Pid}
            end,
        	{ok, Pid};
        {error, {already_started, Pid}} -> 
            %% Code added by wilbur
            io:format("handler already_started~n"),
            %% end
            {ok, Pid};
        {error, Other} -> {error, Other}
    end.

start_handler(SupPid, HandlerID = {Method, Uri, Query}) ->
    %% Code added by wilbur
    io:format("start handler for ~p~n", [HandlerID]),
    %% end
    supervisor:start_child(SupPid,
        {{Method, Uri, Query},
            {coap_handler, start_link, [self(), Uri, Query]},
            temporary, 5000, worker, []}).