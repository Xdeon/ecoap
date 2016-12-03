-module(ecoap_socket).
-behaviour(gen_server).

%% API.
-export([start_link/0, start_link/2, get_endpoint/2, get_all_endpoints/1, close/1]).

%% gen_server.
-export([init/1]).
-export([init/2]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-define(SPEC(MFA),
    {endpoint_sup_sup,
    {endpoint_sup_sup, start_link, [MFA]},
    temporary,
    infinity,
    supervisor,
    [endpoint_sup_sup]}).

-record(state, {
	sock = undefined :: inet:socket(),
	endpoints = undefined :: coap_endpoints(),
	endpoint_refs = undefined :: coap_endpoint_refs(),
	endpoint_pool = undefined :: undefined | pid()
	% deduplication = undefined :: boolean()
}).

-opaque state() :: #state{}.
-type coap_endpoint_id() :: {inet:ip_address(), inet:port_number()}.
-type coap_endpoints() :: #{coap_endpoint_id() => pid()}.
-type coap_endpoint_refs() :: #{reference() => coap_endpoint_id()}.

-export_type([state/0]).
-export_type([coap_endpoint_id/0]).

%% API.

%% client
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
	gen_server:start_link(?MODULE, [0], []).

%% client
-spec close(pid()) -> ok.
close(Pid) ->
	gen_server:cast(Pid, shutdown).

%% server
-spec start_link(pid(), inet:port_number()) -> {ok, pid()} | {error, term()}.
start_link(SupPid, InPort) when is_pid(SupPid) ->
	proc_lib:start_link(?MODULE, init, [SupPid, InPort]).

%% start endpoint manually
-spec get_endpoint(pid(), coap_endpoint_id()) -> {ok, pid()} | term().
get_endpoint(Pid, {PeerIP, PeerPortNo}) ->
    gen_server:call(Pid, {get_endpoint, {PeerIP, PeerPortNo}}).

%% utility function
-spec get_all_endpoints(pid()) -> [pid()].
get_all_endpoints(Pid) ->
	gen_server:call(Pid, get_all_endpoints).

%% gen_server.

init([InPort]) ->
	% process_flag(trap_exit, true),
	% {ok, Deduplication} = application:get_env(deduplication),
	case gen_udp:open(InPort, [binary, {active, true}, {reuseaddr, true}, {recbuf, 1024*1024}]) of
		{ok, Socket} ->
			% We set software buffer to maximum of sndbuf & recbuf of the socket 
			% to avoid unnecessary copying
			% {ok, [{sndbuf, SndBufSize}]} = inet:getopts(Socket, [sndbuf]),
			% {ok, [{recbuf, RecBufSize}]} = inet:getopts(Socket, [recbuf]),
			% ok = inet:setopts(Socket, [{recbuf, RecBufSize * 200}]),
			% ok = inet:setopts(Socket, [{sndbuf, RecBufSize * 200}]),
			% ok = inet:setopts(Socket, [{buffer, max(SndBufSize, RecBufSize)}]),
			{ok, #state{sock=Socket, endpoints=maps:new(), endpoint_refs=maps:new()}};
		{error, Reason} ->
			{stop, Reason}
	end.

init(SupPid, InPort) ->
	case init([InPort]) of
		{ok, State} ->
			error_logger:info_msg("coap listen on *:~p~n", [InPort]),
			register(?MODULE, self()),
			ok = proc_lib:init_ack({ok, self()}),
			{ok, Pid} = supervisor:start_child(SupPid, ?SPEC({endpoint_sup, start_link, []})),
		    link(Pid),
		    gen_server:enter_loop(?MODULE, [], State#state{endpoint_pool=Pid}, {local, ?MODULE});
		{stop, Reason} ->
			ok = proc_lib:init_ack({error, Reason}),
			{error, Reason}
	end.

% get an endpoint when being as a client
handle_call({get_endpoint, EpID}, _From, State=#state{sock=Socket, endpoints=EndPoints, endpoint_pool=undefined}) ->
    case maps:find(EpID, EndPoints) of
        {ok, EpPid} ->
            {reply, {ok, EpPid}, State};
        error ->
            % {ok, EpSupPid, EpPid} = endpoint_sup:start_link(Socket, EpID),
            % %io:fwrite("EpSupPid: ~p EpPid: ~p~n", [EpSupPid, EpPid]),
            {ok, EpPid} = coap_endpoint:start_link(Socket, EpID),
            %io:fwrite("client started~n"),
            {reply, {ok, EpPid}, store_endpoint(EpID, EpPid, State)}
    end;
% get an endpoint when being as a server
handle_call({get_endpoint, EpID}, _From, State=#state{sock=Socket, endpoints=EndPoints, endpoint_pool=PoolPid}) ->
	case maps:find(EpID, EndPoints) of
		{ok, EpPid} ->
			{reply, {ok, EpPid}, State};
		error ->
		    case endpoint_sup_sup:start_endpoint(PoolPid, [Socket, EpID, client]) of
		        {ok, _, EpPid} ->
		            {reply, {ok, EpPid}, store_endpoint(EpID, EpPid, State)};
		        Error ->
		            {reply, Error, State}
		    end
    end;
handle_call(get_all_endpoints, _From, State=#state{endpoints=EndPoints}) ->
	{reply, maps:values(EndPoints), State};
handle_call(_Request, _From, State) ->
	error_logger:error_msg("unexpected call ~p received by ~p as ~p~n", [_Request, self(), ?MODULE]),
	{reply, ignored, State}.

handle_cast(shutdown, State) ->
	{stop, normal, State};
handle_cast(_Msg, State) ->
	error_logger:error_msg("unexpected cast ~p received by ~p as ~p~n", [_Msg, self(), ?MODULE]),
	{noreply, State}.

handle_info({udp, Socket, PeerIP, PeerPortNo, Bin}, State=#state{sock=Socket, endpoints=EndPoints, endpoint_pool=PoolPid}) ->
	EpID = {PeerIP, PeerPortNo},
	% ok = inet:setopts(Socket, [{active, once}]),
	case maps:find(EpID, EndPoints) of
		{ok, EpPid} -> 
			%io:fwrite("found endpoint ~p~n", [EpID]),
			EpPid ! {datagram, Bin},
			erlang:yield(),
			{noreply, State};
		error when is_pid(PoolPid) -> 
			case endpoint_sup_sup:start_endpoint(PoolPid, [Socket, EpID, server]) of
				{ok, _, EpPid} -> 
					%io:fwrite("start endpoint ~p~n", [EpID]),
					EpPid ! {datagram, Bin},
					{noreply, store_endpoint(EpID, EpPid, State)};
				{error, _Reason} -> 
					%io:fwrite("start_endpoint failed: ~p~n", [_Reason]),
					{noreply, State}
			end;
		error ->
			% ignore unexpected message received by a client
			%io:fwrite("client recv unexpected packet~n"),
			{noreply, State}
	end;
handle_info({'DOWN', Ref, process, _Pid, _Reason}, State=#state{endpoints=EndPoints, endpoint_refs=EndPointsRefs}) ->
 	case maps:find(Ref, EndPointsRefs) of
 		error ->	
 			{noreply, State};
 		{ok, EpID} ->
 			{noreply, State#state{endpoints=maps:remove(EpID, EndPoints), endpoint_refs=maps:remove(Ref, EndPointsRefs)}}
 	end;

% handle_info({udp_passive, Socket}, State=#state{sock=Socket}) ->
% 	ok = inet:setopts(Socket, [{active, 100}]),
% 	{noreply, State};

% handle_info({datagram, {PeerIP, PeerPortNo}, Data}, State=#state{sock=Socket}) ->
% 	 ok = gen_udp:send(Socket, PeerIP, PeerPortNo, Data),
%     {noreply, State};

handle_info(_Info, State) ->
    error_logger:error_msg("unexpected info ~p received by ~p as ~p~n", [_Info, self(), ?MODULE]),
	{noreply, State}.

terminate(_Reason, #state{sock=Socket}) ->
	gen_udp:close(Socket),
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%% Internal   
store_endpoint(EpID, EpPid, State=#state{endpoints=EndPoints, endpoint_refs=EndPointsRefs}) ->
	Ref = erlang:monitor(process, EpPid),
	State#state{endpoints=maps:put(EpID, EpPid, EndPoints), endpoint_refs=maps:put(Ref, EpID, EndPointsRefs)}.


