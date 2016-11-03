-module(coap_handler_sup).
-behaviour(supervisor).

-export([start_link/0, get_handler/2]).
-export([init/1]).

start_link() ->
	supervisor:start_link(?MODULE, []).

init([]) ->
	Procs = [],
	{ok, {{one_for_one, 1, 5}, Procs}}.

get_handler(SupPid, HandlerID) ->
    case start_handler(SupPid, HandlerID) of
        {ok, Pid} -> 
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
            {coap_handler, start_link, [self(), Uri]},
            temporary, 5000, worker, []}).