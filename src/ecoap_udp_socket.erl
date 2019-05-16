-module(ecoap_udp_socket).
-behaviour(gen_server).
-behaviour(ecoap_socket).

%% TODO: add supoort for multicast
%% can be done by:
%% 1. add one more param to get_endpoint API to specify if the message to send to a multicast address
%% 2. start endpoint process with EpID set to something like 'multicast' instead of {IP, Port}
%% 3. when receiving a response that can not match an endpoint using {IP, Port}, forward it to the multicast endpoint
%% NOTE: should only apply to client mode
%% NOTE: must also modify ecoap_client and ecoap_endpoint to make them not remove the request record!
%%       since they remove the record after the first response, we can not recv following responses 

%% API.
-export([connect/4, start_link/4, close/1]).
-export([get_endpoint/2, get_all_endpoints/1, get_endpoint_count/1]).
-export([send/3]).

%% gen_server.
-export([init/1]).
-export([handle_continue/2]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-define(ACTIVE_PACKETS, 100).

-record(state, {
	socket = undefined :: inet:socket(),
	server_name = undefined :: atom(),
	endpoint_pool = undefined :: undefined | pid(),
	endpoint_count = 0 :: non_neg_integer(),
	protocol_config = undefined :: ecoap_config:protocol_config()
}).

-opaque state() :: #state{}.

-export_type([state/0]).

%% API.

%% client
-spec connect(ecoap_endpoint:endpoint_addr(), [gen_udp:option()], map(), _) -> {ok, pid()} | {error, term()}.
connect(_EpAddr, TransOpts, ProtoConfig, _TimeOut) ->
	gen_server:start_link(?MODULE, [TransOpts, ProtoConfig], []).

-spec close(pid()) -> ok.
close(Pid) ->
	gen_server:stop(Pid).

%% server
-spec start_link(pid(), atom(), [gen_udp:option()], map()) -> {ok, pid()} | {error, term()}.
start_link(SupPid, Name, TransOpts, ProtoConfig) when is_pid(SupPid) ->
	gen_server:start_link({local, Name}, ?MODULE, [SupPid, Name, TransOpts, ProtoConfig], []).

%% start endpoint manually
-spec get_endpoint(pid(), ecoap_endpoint:endpoint_addr()) -> {ok, pid()} | {error, term()}.
get_endpoint(Pid, EpAddr) ->
    gen_server:call(Pid, {get_endpoint, EpAddr}).

%% utility function
-spec get_all_endpoints(pid()) -> [pid()].
get_all_endpoints(Pid) ->
	gen_server:call(Pid, get_all_endpoints).

-spec get_endpoint_count(pid()) -> non_neg_integer().
get_endpoint_count(Pid) ->
	gen_server:call(Pid, get_endpoint_count).

%% module specific send function 
-spec send(inet:socket(), ecoap_endpoint:ecoap_endpoint_id(), binary()) -> ok | {error, term()}.
send(Socket, {_, {PeerIP, PeerPortNo}}, Datagram) ->
    gen_udp:send(Socket, PeerIP, PeerPortNo, Datagram).

%% gen_server.

init([TransOpts, ProtoConfig]) ->
	case gen_udp:open(0, ecoap_socket:socket_opts(udp, TransOpts)) of
		{ok, Socket} ->
			% logger:log(info, "socket setting: ~p~n", [inet:getopts(Socket, [recbuf, sndbuf, buffer])]),
			logger:log(info, "ecoap listen on *:~p", [inet:port(Socket)]),
			{ok, #state{socket=Socket, protocol_config=ProtoConfig}, {continue, init}};
		Error ->
			{stop, Error}
	end;
init([SupPid, Name, TransOpts, ProtoConfig]) ->
	case init([TransOpts, ProtoConfig]) of
		{ok, State, _} -> 
			ok = ecoap_registry:set_listener(Name, self()),
			{ok, State#state{server_name=Name}, {continue, {init, SupPid}}};
		{stop, {error, Reason}=Error} -> 
			logger:log(error, "Failed to start ecoap listener ~p in ~p:listen (~999999p) for reason ~p", 
				[Name, ?MODULE, TransOpts, Reason]),
			{stop, Error}
	end.

handle_continue(init, State=#state{socket=Socket}) ->
	_ = inet:setopts(Socket, [{active, ?ACTIVE_PACKETS}]),
	{noreply, State};
handle_continue({init, SupPid}, State=#state{socket=Socket}) ->
	{ok, PoolPid} = ecoap_server_sup:start_endpoint_sup_sup(SupPid),
	ok = inet:setopts(Socket, [{active, ?ACTIVE_PACKETS}]),
	{noreply, State#state{endpoint_pool=PoolPid}}.

% get an endpoint when being as a client
handle_call({get_endpoint, EpAddr}, _From, 
	State=#state{socket=Socket, endpoint_pool=undefined, endpoint_count=Count, protocol_config=ProtoConfig}) ->
    case find_endpoint(EpAddr) of
    	{ok, EpPid} ->
    		{reply, {ok, EpPid}, State};
    	error ->
			EpID = {{udp, self()}, EpAddr},
    		case ecoap_endpoint:start_link(?MODULE, Socket, EpID, ProtoConfig) of
    			{ok, EpPid} ->
					store_endpoint(EpAddr, EpPid),
		    		store_endpoint(erlang:monitor(process, EpPid), {EpAddr, undefined}),
		    		{reply, {ok, EpPid}, State#state{endpoint_count=Count+1}};
		    	Error ->
		    		{reply, Error, State}
		    end
    end;
% get an endpoint when being as a server
handle_call({get_endpoint, EpAddr}, _From, 
	State=#state{socket=Socket, endpoint_pool=PoolPid, endpoint_count=Count, server_name=Name}) ->
	case find_endpoint(EpAddr) of
		{ok, EpPid} ->
			{reply, {ok, EpPid}, State};
		error ->
			EpID = {{udp, self()}, EpAddr},
			case endpoint_sup_sup:start_endpoint(PoolPid, [?MODULE, Socket, EpID, Name]) of
		        {ok, EpSupPid, EpPid} ->
					store_endpoint(EpAddr, EpPid),
					store_endpoint(erlang:monitor(process, EpPid), {EpAddr, EpSupPid}),
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
    logger:log(error, "~p recvd unexpected call ~p in ~p", [self(), _Request, ?MODULE]),
	{noreply, State}.

handle_cast(_Msg, State) ->
    logger:log(error, "~p recvd unexpected cast ~p in ~p", [self(), _Msg, ?MODULE]),
	{noreply, State}.

handle_info({udp, Socket, PeerIP, PeerPortNo, Bin}, 
	State=#state{socket=Socket, endpoint_pool=PoolPid, endpoint_count=Count, server_name=Name}) ->
	EpAddr = {PeerIP, PeerPortNo},
	case find_endpoint(EpAddr) of
		{ok, EpPid} ->
			EpPid ! {datagram, Bin},
			{noreply, State};
		error when is_pid(PoolPid) ->
			EpID = {{udp, self()}, EpAddr},
			case endpoint_sup_sup:start_endpoint(PoolPid, [?MODULE, Socket, EpID, Name]) of
				{ok, EpSupPid, EpPid} -> 
					% logger:log(debug, "~p start endpoint as a server in ~p~n", [self(), ?MODULE]),
					EpPid ! {datagram, Bin},
					store_endpoint(EpAddr, EpPid),
					store_endpoint(erlang:monitor(process, EpPid), {EpAddr, EpSupPid}),
					{noreply, State#state{endpoint_count=Count+1}};
				{error, _Reason} -> 
					% logger:log(debug, "~p start endpoint failed as a server in ~p with reason ~p~n", [self(), ?MODULE, Reason]),
					{noreply, State}
			end;
		error ->
			% ignore unexpected message received by a client
		    logger:log(debug, "~p recvd unexpected packet ~p from ~p as a client in ~p", [self(), Bin, EpAddr, ?MODULE]),
		    EpID = {{udp, self()}, EpAddr},
			_ = ecoap_endpoint:maybe_send_rst(?MODULE, Socket, EpID, Bin),
			{noreply, State}
	end;
handle_info({'DOWN', Ref, process, _Pid, _Reason}, State=#state{endpoint_count=Count, endpoint_pool=PoolPid}) ->
 	case find_endpoint(Ref) of
 		{ok, {EpAddr, EpSupPid}} -> 
 			erase_endpoint(Ref),
 			erase_endpoint(EpAddr),
 			ok = delete_endpoint(PoolPid, EpSupPid),
 			{noreply, State#state{endpoint_count=Count-1}};
 		error -> 
 			{noreply, State}
 	end;
handle_info({udp_passive, Socket}, State=#state{socket=Socket}) ->
	_ = inet:setopts(Socket, [{active, ?ACTIVE_PACKETS}]),
	{noreply, State};
	
handle_info(_Info, State) ->
    logger:log(error, "~p recvd unexpected info ~p in ~p", [self(), _Info, ?MODULE]),
	{noreply, State}.

terminate(_Reason, #state{socket=Socket}) ->
	gen_udp:close(Socket),
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%% Internal  

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
