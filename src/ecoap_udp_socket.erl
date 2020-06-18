-module(ecoap_udp_socket).
-behaviour(gen_server).
-behaviour(ecoap_socket).

%% TODO: 
%% add supoort for multicast, can be done as:
%% 1. add one more param to get_endpoint API to specify if the message to send to a multicast address
%% 2. start endpoint process with EpID set to something like 'multicast' instead of {IP, Port}
%% 3. when receiving a response that can not match an endpoint using {IP, Port}, forward it to the multicast endpoint
%% NOTE: should only apply to client mode
%% NOTE: must also modify ecoap_client and ecoap_endpoint to make them not remove the request record!
%%       since they remove the record after the first response, we can not recv following responses 

%% API.
-export([connect/4, start_link/4, close/1]).
-export([get_endpoint/2, wait/1, get_all_endpoints/1]).
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
	endpoints = #{} :: #{ecoap_endpoint:endpoint_addr() => pid()} | #{pid() => {ecoap_endpoint:endpoint_addr(), pid()}},
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
	ok = ecoap_registry:set_new_listener_config(Name, TransOpts, ProtoConfig),
	gen_server:start_link({local, Name}, ?MODULE, [SupPid, Name, TransOpts, ProtoConfig], []).

%% start endpoint manually
-spec get_endpoint(pid(), ecoap_endpoint:endpoint_addr()) -> {ok, pid()} | {error, term()}.
get_endpoint(Pid, EpAddr) ->
    gen_server:call(Pid, {get_endpoint, EpAddr}).

-spec wait(pid()) -> ok.
wait(_) -> ok.

%% utility function
-spec get_all_endpoints(pid()) -> [pid()].
get_all_endpoints(Pid) ->
	gen_server:call(Pid, get_all_endpoints).

%% module specific send function 
-spec send(inet:socket(), ecoap_endpoint:ecoap_endpoint_id(), binary()) -> ok | {error, term()}.
send(Socket, {_, {PeerIP, PeerPortNo}}, Datagram) ->
    gen_udp:send(Socket, PeerIP, PeerPortNo, Datagram).

%% gen_server.
init([TransOpts, ProtoConfig]) ->
	case gen_udp:open(0, ecoap_socket:socket_opts(udp, TransOpts)) of
		{ok, Socket} ->
			process_flag(trap_exit, true),
			{ok, {Addr, Port}} = inet:sockname(Socket),
			logger:log(info, "ecoap listen on UDP ~s:~p", [inet:ntoa(Addr), Port]),
			{ok, #state{socket=Socket, protocol_config=ProtoConfig}, {continue, init}};
		Error ->
			{stop, Error}
	end;
init([SupPid, Name, TransOpts, ProtoConfig]) ->
	case init([TransOpts, ProtoConfig]) of
		{ok, State, _} -> 
			ok = ecoap_registry:set_listener(Name, self()),
			{ok, State#state{server_name=Name}, {continue, {init, SupPid}}};
		{stop, {error, Reason}} -> 
			logger:log(error, "Failed to start ecoap listener ~p in ~p:listen (~999999p) for reason ~p (~s)~n", 
			[Name, ?MODULE, TransOpts, Reason, inet:format_error(Reason)]),
			{stop, {listen_error, Name, Reason}}
	end.

handle_continue(init, State=#state{socket=Socket}) ->
	_ = inet:setopts(Socket, [{active, ?ACTIVE_PACKETS}]),
	{noreply, State};
handle_continue({init, SupPid}, State=#state{socket=Socket}) ->
	EpPool = ecoap_server_sup:find_child(SupPid, ecoap_endpoint_sup_sup),
	ok = inet:setopts(Socket, [{active, ?ACTIVE_PACKETS}]),
	{noreply, State#state{endpoint_pool=EpPool}}.

% get an endpoint when being as a client
handle_call({get_endpoint, EpAddr}, _From, 
	State=#state{socket=Socket, endpoint_pool=undefined, protocol_config=ProtoConfig}) ->
    case find_endpoint(EpAddr, State) of
    	{ok, EpPid} ->
    		{reply, {ok, EpPid}, State};
    	error ->
			EpID = {{udp, self()}, EpAddr},
    		case ecoap_endpoint:start_link(?MODULE, Socket, EpID, ProtoConfig) of
    			{ok, EpPid} ->
					_ = erlang:monitor(process, EpPid),
		    		{reply, {ok, EpPid}, store_endpoint(EpAddr, EpPid, undefined, State)};
		    	Error ->
		    		{reply, Error, State}
		    end
    end;
% get an endpoint when being as a server
handle_call({get_endpoint, EpAddr}, _From, 
	State=#state{socket=Socket, endpoint_pool=EpPool, server_name=Name}) ->
	case find_endpoint(EpAddr, State) of
		{ok, EpPid} ->
			{reply, {ok, EpPid}, State};
		error ->
			EpID = {{udp, self()}, EpAddr},
			case ecoap_endpoint_sup_sup:start_endpoint(EpPool, [?MODULE, Socket, EpID, Name]) of
		        {ok, EpSupPid, EpPid} ->
					_ = erlang:monitor(process, EpPid),
		            {reply, {ok, EpPid}, store_endpoint(EpAddr, EpPid, EpSupPid, State)};
		        Error ->
		            {reply, Error, State}
		    end
	end;
% only for debug use
handle_call(get_all_endpoints, _From, State) ->
	EpPids = fetch_endpoint_pids(State),
	{reply, EpPids, State};
handle_call(_Request, _From, State) ->
    logger:log(error, "~p recvd unexpected call ~p in ~p~n", [self(), _Request, ?MODULE]),
	{noreply, State}.

handle_cast(_Msg, State) ->
    logger:log(error, "~p recvd unexpected cast ~p in ~p~n", [self(), _Msg, ?MODULE]),
	{noreply, State}.

handle_info({udp, Socket, PeerIP, PeerPortNo, Bin}, 
	State=#state{socket=Socket, endpoint_pool=EpPool, server_name=Name}) ->
	EpAddr = {PeerIP, PeerPortNo},
	case find_endpoint(EpAddr, State) of
		{ok, EpPid} ->
			EpPid ! {datagram, Bin},
			{noreply, State};
		error when is_pid(EpPool) ->
			EpID = {{udp, self()}, EpAddr},
			case ecoap_endpoint_sup_sup:start_endpoint(EpPool, [?MODULE, Socket, EpID, Name]) of
				{ok, EpSupPid, EpPid} -> 
					% logger:log(debug, "~p start endpoint as a server in ~p~n", [self(), ?MODULE]),
					EpPid ! {datagram, Bin},
					_ = erlang:monitor(process, EpPid),
					{noreply, store_endpoint(EpAddr, EpPid, EpSupPid, State)};
				{error, _Reason} -> 
					% logger:log(debug, "~p start endpoint failed as a server in ~p with reason ~p~n", [self(), ?MODULE, Reason]),
					{noreply, State}
			end;
		error ->
			% ignore unexpected message received by a client
			logger:log(debug, "~p received unexpected packet ~p from ~p as a client in ~p~n", [self(), Bin, EpAddr, ?MODULE]),
			{noreply, State}
	end;
handle_info({'DOWN', _Ref, process, EpPid, _Reason}, State=#state{endpoint_pool=EpPool}) ->
 	case find_endpoint(EpPid, State) of
 		{ok, {EpAddr, EpSupPid}} -> 
 			ok = stop_endpoint(EpPool, EpSupPid),
 			{noreply, erase_endpoint(EpAddr, EpPid, State)};
 		error -> 
 			{noreply, State}
 	end;
handle_info({udp_passive, Socket}, State=#state{socket=Socket}) ->
	_ = inet:setopts(Socket, [{active, ?ACTIVE_PACKETS}]),
	{noreply, State};
	
handle_info(_Info, State) ->
    logger:log(error, "~p recvd unexpected info ~p in ~p~n", [self(), _Info, ?MODULE]),
	{noreply, State}.

terminate(_Reason, #state{socket=Socket}) ->
	gen_udp:close(Socket),
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%% Internal  

find_endpoint(Key, #state{endpoints=Endpoints}) ->
	maps:find(Key, Endpoints).

store_endpoint(EpAddr, EpPid, EpSupPid, State=#state{endpoints=Endpoints}) ->
	State#state{endpoints=maps:put(EpPid, {EpAddr, EpSupPid}, maps:put(EpAddr, EpPid, Endpoints))}.

erase_endpoint(EpAddr, EpPid, State=#state{endpoints=Endpoints}) ->
	State#state{endpoints=maps:remove(EpPid, maps:remove(EpAddr, Endpoints))}.

stop_endpoint(EpPool, EpSupPid) when is_pid(EpSupPid) ->
	ecoap_endpoint_sup_sup:stop_endpoint(EpPool, EpSupPid);
stop_endpoint(_, _) -> 
 	ok.

fetch_endpoint_pids(#state{endpoints=Endpoints}) ->
	maps:values(maps:filter(fun(K, _) when is_tuple(K) -> true; (_, _) -> false end, Endpoints)).