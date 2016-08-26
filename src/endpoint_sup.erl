-module(endpoint_sup).
-behaviour(supervisor).

-export([start_link/2]).
-export([init/1]).

%% Only applies to one time use supervision tree...

% start_link(Socket, EpID) ->
%     {ok, SupPid} = supervisor:start_link(?MODULE, []),
%     {ok, HdlSupPid} = supervisor:start_child(SupPid, 
%       	{coap_handler_sup,
%   		     {coap_handler_sup, start_link, []},
%   		      permanent, infinity, supervisor, 
%            [coap_handler_sup]}),
%     {ok, EpPid} = supervisor:start_child(SupPid,
%         {coap_endpoint,
%           {coap_endpoint, start_link, [Socket, EpID, HdlSupPid]},
%           transient, 5000, worker, 
%           [coap_endpoint]}),
%     {ok, SupPid, EpPid}.

start_link(Socket, EpID) ->
    {ok, SupPid} = supervisor:start_link(?MODULE, []),
    {ok, EpPid} = supervisor:start_child(SupPid,
        {coap_endpoint,
          {coap_endpoint, start_link, [SupPid, Socket, EpID]},
          transient, 5000, worker, 
          [coap_endpoint]}),
    {ok, SupPid, EpPid}.

init([]) ->
    % crash of any worker will terminate the supervisor and invoke start_link/2 again
    {ok, {#{strategy => one_for_all, intensity => 0, period => 1}, []}}.


