-module(ecoap_udp_socket).
-behaviour(gen_server).

%% API.
-export([start_link/1, start_link/2, close/1]).
-export([get_endpoint/2, get_all_endpoints/1, get_endpoint_count/1]).
-export([send_datagram/3]).

%% gen_server.
-export([init/1]).
-export([init/2]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-define(ACTIVE_PACKETS, 100).
-define(READ_PACKETS, 1000).

-define(DEFAULT_SOCK_OPTS,
	[binary, {active, ?ACTIVE_PACKETS}, {reuseaddr, true}, {read_packets, ?READ_PACKETS}]).

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
-spec start_link([gen_udp:option()]) -> {ok, pid()} | {error, term()}.
start_link(SocketOpts) ->
	gen_server:start_link(?MODULE, [SocketOpts], []).

%% client
-spec close(pid()) -> ok.
close(Pid) ->
	gen_server:stop(Pid).

%% server
-spec start_link(pid(), [gen_udp:option()]) -> {ok, pid()} | {error, term()}.
start_link(SupPid, SocketOpts) when is_pid(SupPid) ->
	proc_lib:start_link(?MODULE, init, [SupPid, SocketOpts]).

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

init([SocketOpts]) ->
	% process_flag(trap_exit, true),
	{ok, Socket} = gen_udp:open(0, merge_opts(?DEFAULT_SOCK_OPTS, SocketOpts)),
	error_logger:info_msg("socket setting: ~p~n", [inet:getopts(Socket, [recbuf, sndbuf, buffer])]),
	error_logger:info_msg("coap listen on *:~p~n", [inet:port(Socket)]),
	{ok, #state{sock=Socket}}.

init(SupPid, SocketOpts) ->
	{ok, State} = init([SocketOpts]),
	register(?MODULE, self()),
	ok = proc_lib:init_ack({ok, self()}),
 	PoolPid = ecoap_server_sup:endpoint_sup_sup(SupPid),
    gen_server:enter_loop(?MODULE, [], State#state{endpoint_pool=PoolPid}, {local, ?MODULE}).

% get an endpoint when being as a client
handle_call({get_endpoint, EpID}, _From, State=#state{sock=Socket, endpoint_pool=undefined, endpoint_count=Count}) ->
    case find_endpoint(EpID) of
    	{ok, EpPid} ->
    		{reply, {ok, EpPid}, State};
    	error ->
    		{ok, EpPid} = ecoap_endpoint:start_link(?MODULE, Socket, EpID),
    		store_endpoint(EpID, EpPid),
    		store_endpoint(erlang:monitor(process, EpPid), {EpID, undefined}),
    		{reply, {ok, EpPid}, State#state{endpoint_count=Count+1}}
    end;
% get an endpoint when being as a server
handle_call({get_endpoint, EpID}, _From, State=#state{sock=Socket, endpoint_pool=PoolPid, endpoint_count=Count}) ->
	case find_endpoint(EpID) of
		{ok, EpPid} ->
			{reply, {ok, EpPid}, State};
		error ->
			case endpoint_sup_sup:start_endpoint(PoolPid, [?MODULE, Socket, EpID]) of
		        {ok, EpSupPid, EpPid} ->
					store_endpoint(EpID, EpPid),
					store_endpoint(erlang:monitor(process, EpPid), {EpID, EpSupPid}),
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
				{ok, EpSupPid, EpPid} -> 
					%io:fwrite("start endpoint ~p~n", [EpID]),
					EpPid ! {datagram, Bin},
					store_endpoint(EpID, EpPid),
					store_endpoint(erlang:monitor(process, EpPid), {EpID, EpSupPid}),
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
handle_info({'DOWN', Ref, process, _Pid, _Reason}, State=#state{endpoint_count=Count, endpoint_pool=PoolPid}) ->
 	case find_endpoint(Ref) of
 		{ok, {EpID, EpSupPid}} -> 
 			erase_endpoint(Ref),
 			erase_endpoint(EpID),
 			ok = delete_endpoint(PoolPid, EpSupPid),
 			{noreply, State#state{endpoint_count=Count-1}};
 		error -> 
 			{noreply, State}
 	end;
handle_info({udp_passive, Socket}, State=#state{sock=Socket}) ->
	ok = inet:setopts(Socket, [{active, ?ACTIVE_PACKETS}]),
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

find_endpoint(Key) ->
	case get(Key) of
		undefined -> error;
		Val -> {ok, Val}
	end.

store_endpoint(Key, Val) ->
	put(Key, Val).

erase_endpoint(Key) ->
	erase(Key).

delete_endpoint(PoolPid, EpSupPid) when is_pid(EpSupPid) ->
	endpoint_sup_sup:delete_endpoint(PoolPid, EpSupPid);
delete_endpoint(_, _) -> 
 	ok.

fetch_endpoint_pids() ->
	[Val || {{_, _}, Val} <- get(), is_pid(Val)].
