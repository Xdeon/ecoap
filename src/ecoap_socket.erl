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
-type coap_endpoint_refs() :: #{reference() => {coap_endpoint_id(), pid()}}.

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
get_all_endpoints(Pid) ->
	gen_server:call(Pid, get_all_endpoints).

%% gen_server.

init([InPort]) ->
	% process_flag(trap_exit, true),
	% {ok, Deduplication} = application:get_env(deduplication),
	case gen_udp:open(InPort, [binary, {active, once}, {reuseaddr, true}]) of
		{ok, Socket} ->
			% We set software buffer to maximum of sndbuf & recbuf of the socket 
			% to avoid unnecessary copying
			{ok, [{sndbuf, SndBufSize}]} = inet:getopts(Socket, [sndbuf]),
			{ok, [{recbuf, RecBufSize}]} = inet:getopts(Socket, [recbuf]),
			ok = inet:setopts(Socket, [{buffer, max(SndBufSize, RecBufSize)}]),
			error_logger:info_msg("coap listen on *:~p~n", [InPort]),
			{ok, #state{sock=Socket, endpoints=maps:new(), endpoint_refs=maps:new()}};
		{error, Reason} ->
			{stop, Reason}
	end.

init(SupPid, InPort) ->
	case init([InPort]) of
		{ok, State} ->
			register(?MODULE, self()),
			ok = proc_lib:init_ack({ok, self()}),
			{ok, Pid} = supervisor:start_child(SupPid, ?SPEC({endpoint_sup, start_link, []})),
		    link(Pid),
		    gen_server:enter_loop(?MODULE, [], State#state{endpoint_pool=Pid}, {local, ?MODULE});
		{stop, Reason} ->
			ok = proc_lib:init_ack({error, Reason}),
			{error, Reason}
	end.

handle_call({get_endpoint, EpID}, _From, State=#state{endpoints=EndPoints, endpoint_pool=undefined, sock=Socket}) ->
    case find_endpoint(EpID, EndPoints) of
        {ok, EpPid} ->
            {reply, {ok, EpPid}, State};
        undefined ->
            % {ok, EpSupPid, EpPid} = endpoint_sup:start_link(Socket, EpID),
            % %iofwrite("EpSupPid: ~p EpPid: ~p~n", [EpSupPid, EpPid]),
            {ok, EpPid} = coap_endpoint:start_link(Socket, EpID),
            %iofwrite("client started~n"),
            {reply, {ok, EpPid}, store_endpoint(EpID, EpPid, State)}
    end;
handle_call({get_endpoint, EpID}, _From, State=#state{endpoints=EndPoints, endpoint_pool=PoolPid, sock=Socket}) ->
	case find_endpoint(EpID, EndPoints) of
		{ok, EpPid} ->
			{reply, {ok, EpPid}, State};
		undefined ->
		    case endpoint_sup_sup:start_endpoint(PoolPid, [Socket, EpID]) of
		        {ok, _, EpPid} ->
		            {reply, {ok, EpPid}, store_endpoint(EpID, EpPid, State)};
		        Error ->
		            {reply, Error, State}
		    end
    end;
handle_call(get_all_endpoints, _From, State=#state{endpoints=EndPoints}) ->
	{reply, maps:values(EndPoints), State};
handle_call(_Request, _From, State) ->
	{reply, ignored, State}.

handle_cast(shutdown, State) ->
	{stop, normal, State};
handle_cast(_Msg, State) ->
	{noreply, State}.

handle_info({udp, Socket, PeerIP, PeerPortNo, Bin}, State=#state{sock=Socket, endpoints=EndPoints, endpoint_pool=PoolPid}) ->
	EpID = {PeerIP, PeerPortNo},
	ok = inet:setopts(Socket, [{active, once}]),
	case find_endpoint(EpID, EndPoints) of
		{ok, EpPid} -> 
			%iofwrite("found endpoint ~p~n", [EpID]),
			EpPid ! {datagram, Bin},
			{noreply, State};
		undefined when is_pid(PoolPid) -> 
			case endpoint_sup_sup:start_endpoint(PoolPid, [Socket, EpID]) of
				{ok, _, EpPid} -> 
					%iofwrite("start endpoint ~p~n", [EpID]),
					EpPid ! {datagram, Bin},
					{noreply, store_endpoint(EpID, EpPid, State)};
				{error, _Reason} -> 
					%iofwrite("start_endpoint failed: ~p~n", [_Reason]),
					{noreply, State}
			end;
		undefined ->
			% ignore unexpected message received by a client
			%iofwrite("client recv unexpected packet~n"),
			{noreply, State}
	end;
handle_info({'DOWN', Ref, process, _Pid, _Reason}, State=#state{endpoints=EndPoints, endpoint_refs=EndPointsRefs}) ->
 	case maps:find(Ref, EndPointsRefs) of
 		error ->	
 			{noreply, State};
 		{ok, EpID} ->
			error_logger:error_msg("coap_endpoint ~p stopped with reason ~p~n", [EpID, _Reason]),
 			{noreply, State#state{endpoints=maps:remove(EpID, EndPoints), endpoint_refs=maps:remove(Ref, EndPointsRefs)}}
 	end;
handle_info(_Info, State) ->
	%iofwrite("ecoap_socket recv unexpected info ~p~n", [_Info]),
	{noreply, State}.

terminate(_Reason, #state{sock=Socket}) ->
	gen_udp:close(Socket),
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%% Internal   
find_endpoint(EpID, EndPoints) ->
    case maps:find(EpID, EndPoints) of
        error -> undefined;
        {ok, EpPid} -> {ok, EpPid}
    end.

store_endpoint(EpID, EpPid, State=#state{endpoints=EndPoints, endpoint_refs=EndPointsRefs}) ->
	Ref = erlang:monitor(process, EpPid),
	State#state{endpoints=maps:put(EpID, EpPid, EndPoints), endpoint_refs=maps:put(Ref, EpID, EndPointsRefs)}.


