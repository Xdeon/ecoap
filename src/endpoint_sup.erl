-module(endpoint_sup).
-behaviour(supervisor).

-export([start_link/2]).
-export([init/1]).

% start_link() ->
% 	supervisor:start_link({local, ?MODULE}, ?MODULE, []).

% init([]) ->
% 	Procs = [],
% 	{ok, {{one_for_one, 1, 5}, Procs}}.

start_link(Socket, EpID) ->
    {ok, SupPid} = supervisor:start_link(?MODULE, []),
    {ok, EpPid} = supervisor:start_child(SupPid,
        {coap_endpoint,
            {coap_endpoint, start_link, [SupPid, Socket, EpID]},
            transient, 5000, worker, []}),
    {ok, SupPid, EpPid}.

init([]) ->
    % crash of any worker will terminate the supervisor and invoke start_link/2 again
    {ok, {{one_for_all, 0, 1}, []}}.