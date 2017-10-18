-module(ecoap_udp_socket).
-behaviour(gen_server).

%% API.
-export([start_link/0, start_link/3, close/1]).
-export([get_endpoint/2, get_all_endpoints/1, get_endpoint_count/1]).
-export([send_datagram/3]).

%% gen_server.
-export([init/1]).
-export([init/3]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

%% TODO: are configurable {active, N} necessary here?
%% parameters below highly depend on experiments
%% they give acceptable performance on AWS EC2 instance
-define(LOW_ACTIVE_PACKETS, 100).
-define(MEDIUM_ACTIVE_PACKETS, 200).
-define(HIGH_ACTIVE_PACKETS, 400).
-define(LOW_CONCURRENCY_THRESHOLD, 800).
-define(HIGH_CONCURRENCY_THRESHOLD, 2000).

-define(DEFAULT_SOCK_OPTS,
	[binary, {active, ?LOW_ACTIVE_PACKETS}, {reuseaddr, true}]).

-record(state, {
	sock = undefined :: inet:socket(),
	endpoint_pool = undefined :: undefined | pid(),
	endpoint_count = 0 :: non_neg_integer()
}).

-opaque state() :: #state{}.
-type ecoap_endpoint_id() :: {inet:ip_address(), inet:port_number()}.

-export_type([state/0]).
-export_type([ecoap_endpoint_id/0]).

%% API.

%% client
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
	gen_server:start_link(?MODULE, [0, []], []).

%% client
-spec close(pid()) -> ok.
close(Pid) ->
	gen_server:cast(Pid, shutdown).

%% server
-spec start_link(pid(), inet:port_number(), [gen_udp:option()]) -> {ok, pid()} | {error, term()}.
start_link(SupPid, InPort, Opts) when is_pid(SupPid) ->
	proc_lib:start_link(?MODULE, init, [SupPid, InPort, Opts]).

%% start endpoint manually
-spec get_endpoint(pid(), ecoap_endpoint_id()) -> {ok, pid()} | term().
get_endpoint(Pid, {PeerIP, PeerPortNo}) ->
    gen_server:call(Pid, {get_endpoint, {PeerIP, PeerPortNo}}).

%% utility function
-spec get_all_endpoints(pid()) -> [pid()].
get_all_endpoints(Pid) ->
	gen_server:call(Pid, get_all_endpoints).

-spec get_endpoint_count(pid()) -> non_neg_integer().
get_endpoint_count(Pid) ->
	gen_server:call(Pid, get_endpoint_count).

%% module specific send function 
-spec send_datagram(inet:socket(), ecoap_udp_socket:ecoap_endpoint_id(), binary()) -> ok.
send_datagram(Socket, {PeerIP, PeerPortNo}, Datagram) ->
    inet_udp:send(Socket, PeerIP, PeerPortNo, Datagram).

%% gen_server.

init([InPort, Opts]) ->
	% process_flag(trap_exit, true),
	{ok, Socket} = gen_udp:open(InPort, merge_opts(?DEFAULT_SOCK_OPTS, Opts)),
	io:format("socket setting: ~p~n", [inet:getopts(Socket, [recbuf, sndbuf, buffer])]),
	{ok, #state{sock=Socket}}.

init(SupPid, InPort, Opts) ->
	{ok, State} = init([InPort, Opts]),
	error_logger:info_msg("coap listen on *:~p~n", [InPort]),
	register(?MODULE, self()),
	ok = proc_lib:init_ack({ok, self()}),
 	{_, Pid, _, _} = lists:keyfind(endpoint_sup_sup, 1, supervisor:which_children(SupPid)),
    gen_server:enter_loop(?MODULE, [], State#state{endpoint_pool=Pid}, {local, ?MODULE}).

% get an endpoint when being as a client
handle_call({get_endpoint, EpID}, _From, State=#state{sock=Socket, endpoint_pool=undefined, endpoint_count=Count}) ->
    case find_endpoint(EpID) of
    	{ok, EpPid} ->
    		{reply, {ok, EpPid}, State};
    	error ->
    		{ok, EpPid} = ecoap_endpoint:start_link(?MODULE, Socket, EpID),
    		store_endpoint(EpID, EpPid),
    		store_endpoint(erlang:monitor(process, EpPid), EpID),
    		{reply, {ok, EpPid}, State#state{endpoint_count=Count+1}}
    end;
% get an endpoint when being as a server
handle_call({get_endpoint, EpID}, _From, State=#state{sock=Socket, endpoint_pool=PoolPid, endpoint_count=Count}) ->
	case find_endpoint(EpID) of
		{ok, EpPid} ->
			{reply, {ok, EpPid}, State};
		error ->
			case endpoint_sup_sup:start_endpoint(PoolPid, [?MODULE, Socket, EpID]) of
		        {ok, _, EpPid} ->
					store_endpoint(EpID, EpPid),
					store_endpoint(erlang:monitor(process, EpPid), EpID),
		            {reply, {ok, EpPid}, State#state{endpoint_count=Count+1}};
		        Error ->
		            {reply, Error, State}
		    end
	end;
% only for debug use
handle_call(get_all_endpoints, _From, State) ->
	EpPids = fetch_endpoint_pids(),
	{reply, EpPids, State};
handle_call(get_endpoint_count, _From, State=#state{endpoint_count=Count}) ->
	{reply, Count, State};
handle_call(_Request, _From, State) ->
	error_logger:error_msg("unexpected call ~p received by ~p as ~p~n", [_Request, self(), ?MODULE]),
	{noreply, State}.

handle_cast(shutdown, State) ->
	{stop, normal, State};
handle_cast(_Msg, State) ->
	error_logger:error_msg("unexpected cast ~p received by ~p as ~p~n", [_Msg, self(), ?MODULE]),
	{noreply, State}.

handle_info({udp, Socket, PeerIP, PeerPortNo, Bin}, State=#state{sock=Socket, endpoint_pool=PoolPid, endpoint_count=Count}) ->
	EpID = {PeerIP, PeerPortNo},
	case find_endpoint(EpID) of
		{ok, EpPid} ->
			EpPid ! {datagram, Bin},
			{noreply, State};
		error when is_pid(PoolPid) ->
			case endpoint_sup_sup:start_endpoint(PoolPid, [?MODULE, Socket, EpID]) of
				{ok, _, EpPid} -> 
					%io:fwrite("start endpoint ~p~n", [EpID]),
					EpPid ! {datagram, Bin},
					store_endpoint(EpID, EpPid),
					store_endpoint(erlang:monitor(process, EpPid), EpID),
					{noreply, State#state{endpoint_count=Count+1}};
				{error, _Reason} -> 
					%io:fwrite("start_endpoint failed: ~p~n", [_Reason]),
					{noreply, State}
			end;
		error ->
			% ignore unexpected message received by a client
			%io:fwrite("client recv unexpected packet~n"),
			{noreply, State}
	end;
handle_info({'DOWN', Ref, process, _Pid, _Reason}, State=#state{endpoint_count=Count}) ->
 	case find_endpoint(Ref) of
 		{ok, EpID} -> 
 			erase_endpoint(Ref),
 			erase_endpoint(EpID),
 			{noreply, State#state{endpoint_count=Count-1}};
 		error -> 
 			{noreply, State}
 	end;
handle_info({udp_passive, Socket}, State=#state{sock=Socket}) ->
	ActivePackets = next_active_packets(State),
	ok = inet:setopts(Socket, [{active, ActivePackets}]),
	{noreply, State};
	
handle_info(_Info, State) ->
    error_logger:error_msg("unexpected info ~p received by ~p as ~p~n", [_Info, self(), ?MODULE]),
	{noreply, State}.

terminate(_Reason, #state{sock=Socket}) ->
	gen_udp:close(Socket),
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%% Internal  

merge_opts(Defaults, Options) ->
    lists:foldl(
        fun({Opt, Val}, Acc) ->
                lists:keystore(Opt, 1, Acc, {Opt, Val});
            (Opt, Acc) ->
                case lists:member(Opt, Acc) of
                    true  -> Acc;
                    false -> [Opt | Acc]
                end
    end, Defaults, Options).

next_active_packets(State) ->
	Concurrency = State#state.endpoint_count,
	if 
		Concurrency < ?LOW_CONCURRENCY_THRESHOLD -> ?LOW_ACTIVE_PACKETS;
		Concurrency < ?HIGH_CONCURRENCY_THRESHOLD -> ?MEDIUM_ACTIVE_PACKETS;
		true -> ?HIGH_ACTIVE_PACKETS
	end.

find_endpoint(Key) ->
	case get(Key) of
		undefined -> error;
		Val -> {ok, Val}
	end.

store_endpoint(Key, Val) ->
	put(Key, Val).

erase_endpoint(Key) ->
	erase(Key).

fetch_endpoint_pids() ->
	[Val || {{_, _}, Val} <- get(), is_pid(Val)].

% -ifdef(TEST).

% -include_lib("eunit/include/eunit.hrl").

% store_endpoint_test() ->
% 	EpID = {{127,0,0,1}, 5683},
% 	store_endpoint(EpID, self()),
% 	State = store_endpoint_monitor(EpID, self(), #state{}),
% 	[Ref] = maps:keys(State#state.endpoint_refs),
% 	?assertEqual({ok, self()}, find_endpoint(EpID)),
% 	?assertEqual({ok, EpID}, find_endpoint_monitor(Ref, State)),
% 	?assertEqual([self()], fetch_endpoint_pids(State)),
% 	erase_endpoint(EpID),
% 	State1 = erase_endpoint_monitor(Ref, State),
% 	?assertEqual(error, find_endpoint(EpID)),
% 	?assertEqual(error, find_endpoint_monitor(Ref, State1)),
% 	?assertEqual([], fetch_endpoint_pids(State1)).

% -endif.

