-module(ecoap_socket).
-behaviour(gen_server).

%% API.
-export([start_link/0, start_link/2, get_endpoint/2, close/1]).

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
}).

-opaque state() :: #state{}.
-export_type([state/0]).

-include("coap.hrl").

%% API.

%% client
-spec start_link() -> {ok, pid()}.
start_link() ->
	gen_server:start_link(?MODULE, [0], []).

%% server
-spec start_link(pid(), inet:port_number()) -> {ok, pid()}.
start_link(SupPid, InPort) when is_pid(SupPid) ->
	proc_lib:start_link(?MODULE, init, [SupPid, InPort]).

%% start endpoint manually
-spec get_endpoint(pid(), coap_endpoint_id()) -> {ok, pid()}.
get_endpoint(Pid, {PeerIP, PeerPortNo}) ->
    gen_server:call(Pid, {get_endpoint, {PeerIP, PeerPortNo}}).

%% client
-spec close(pid()) -> ok.
close(Pid) ->
	gen_server:cast(Pid, shutdown).

%% gen_server.
-spec init([inet:port_number()]) -> {ok, state()} | {stop, any()}.
init([InPort]) ->
	% process_flag(trap_exit, true),
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

-spec init(pid(), inet:port_number()) -> no_return().
init(SupPid, InPort) ->
	register(?MODULE, self()),
	{ok, State} = init([InPort]),
	ok = proc_lib:init_ack({ok, self()}),
	{ok, Pid} = supervisor:start_child(SupPid, ?SPEC({endpoint_sup, start_link, []})),
    link(Pid),
    gen_server:enter_loop(?MODULE, [], State#state{endpoint_pool=Pid}, {local, ?MODULE}).

-spec handle_call({get_endpoint, coap_endpoint_id()}, from(), State) -> {reply, {ok, pid()} | term(), State} when State :: state().
handle_call({get_endpoint, EpID}, _From, State=#state{endpoints=EndPoints, endpoint_pool=undefined, sock=Socket}) ->
    case find_endpoint(EpID, EndPoints) of
        {ok, EpPid} ->
            {reply, {ok, EpPid}, State};
        undefined ->
            % {ok, EpSupPid, EpPid} = endpoint_sup:start_link(Socket, EpID),
            % io:fwrite("EpSupPid: ~p EpPid: ~p~n", [EpSupPid, EpPid]),
            {ok, EpPid} = coap_endpoint:start_link(Socket, EpID),
            io:fwrite("client started~n"),
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
handle_call(_Request, _From, State) ->
	{reply, ignored, State}.

-spec handle_cast(shutdown, State) -> {stop, normal, State} when State :: state().
handle_cast(shutdown, State) ->
	{stop, normal, State};
handle_cast(_Msg, State) ->
	{noreply, State}.

-spec handle_info({udp, inet:socket(), inet:ip_address(), inet:port_number(), binary()}, State) -> {noreply, State}; 
	({'DOWN', reference(), process, pid(), any()}, State) -> {noreply, State} when State :: state().
handle_info({udp, Socket, PeerIP, PeerPortNo, Bin}, State=#state{sock=Socket, endpoints=EndPoints, endpoint_pool=PoolPid}) ->
	EpID = {PeerIP, PeerPortNo},
	ok = inet:setopts(Socket, [{active, once}]),
	case find_endpoint(EpID, EndPoints) of
		{ok, EpPid} -> 
			io:fwrite("found endpoint ~p~n", [EpID]),
			EpPid ! {datagram, Bin},
			{noreply, State};
		undefined when is_pid(PoolPid) -> 
			case endpoint_sup_sup:start_endpoint(PoolPid, [Socket, EpID]) of
				{ok, _, EpPid} -> 
					io:fwrite("start endpoint ~p~n", [EpID]),
					EpPid ! {datagram, Bin},
					{noreply, store_endpoint(EpID, EpPid, State)};
				{error, _Reason} -> 
					io:fwrite("start_endpoint failed: ~p~n", [_Reason]),
					{noreply, State}
			end;
		undefined ->
			% ignore unexpected message received by a client
			io:fwrite("client recv unexpected packet~n"),
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
	io:fwrite("ecoap_socket recv unexpected info ~p~n", [_Info]),
	{noreply, State}.

-spec terminate(any(), state()) -> ok.
terminate(_Reason, #state{sock=Socket}) ->
	gen_udp:close(Socket),
	ok.

-spec code_change(_, _, _) -> {ok, _}.
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


