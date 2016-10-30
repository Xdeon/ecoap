-module(coap_handler_sup).
-behaviour(supervisor).

-export([start_link/0, get_handler/2]).
-export([init/1]).

-include("coap.hrl").

start_link() ->
	supervisor:start_link(?MODULE, []).

init([]) ->
	Procs = [],
	{ok, {{one_for_one, 1, 5}, Procs}}.

get_handler(SupPid, Request) ->
    case start_handler(SupPid, Request) of
        {ok, Pid} -> 
        	{ok, Pid};
        {error, {already_started, Pid}} -> 
            %% Code added by wilbur
            io:format("handler already_started~n"),
            %% end
            {ok, Pid};
        {error, Other} -> {error, Other}
    end.

start_handler(SupPid, #coap_message{code=Method, options=Options}) ->
    Uri = proplists:get_value('Uri-Path', Options, []),
    Query = proplists:get_value('Uri-Query', Options, []),
    %% Code added by wilbur
    io:format("start handler for ~p~n", [{Method, Uri, Query}]),
    %% end
    supervisor:start_child(SupPid,
        {{Method, Uri, Query},
            {coap_handler, start_link, [self(), Uri]},
            temporary, 5000, worker, []}).