-module(coap_handler_sup).
-behaviour(supervisor).

-export([start_link/0, get_handler/3]).
-export([init/1]).

start_link() ->
	supervisor:start_link(?MODULE, []).

init([]) ->
    Procs = [
        {coap_handler,
            {coap_handler, start_link, []},
            temporary, 5000, worker, [coap_handler]
        }
    ],
    {ok, {{simple_one_for_one, 0, 1}, Procs}}.

get_handler(SupPid, HandlerID, HandlerRegs) ->
    case maps:find(HandlerID, HandlerRegs) of
        error ->          
            start_handler(SupPid, HandlerID);
        {ok, Pid} ->
            {ok, Pid}
    end.

start_handler(SupPid, HandlerID) ->
    supervisor:start_child(SupPid, [self(), HandlerID]).

% init([]) ->
% 	Procs = [],
% 	{ok, {{one_for_one, 3, 10}, Procs}}.

% get_handler(EndpointPid, SupPid, HandlerID, Observable) ->
%     case start_handler(SupPid, HandlerID) of
%         {ok, Pid} -> 
%             % io:format("start handler for ~p~n", [HandlerID]),
%             ok = obs_handler_notify(EndpointPid, Observable, Pid),
%         	{ok, Pid};
%         {error, {already_started, Pid}} -> 
%             %% Code added by wilbur
%             %io:format("handler already_started~n"),
%             %% end
%             {ok, Pid};
%         {error, Other} -> {error, Other}
%     end.

% start_handler(SupPid, HandlerID = {_, Uri, Query}) ->
%     %% Code added by wilbur
%     % io:format("start handler for ~p~n", [HandlerID]),
%     %% end
%     supervisor:start_child(SupPid,
%         {HandlerID,
%             {coap_handler, start_link, [self(), Uri, Query]},
%             temporary, 5000, worker, [coap_handler]}).

% obs_handler_notify(EndpointPid, Observable, Pid) ->
%     case Observable of
%         undefined -> ok;
%         _Else ->  EndpointPid ! {obs_handler_started, Pid}, ok
%     end.