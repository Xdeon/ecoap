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
            {ok, EpPid} = coap_endpoint:start_link(Socket, EpID),
            % io:fwrite("EpSupPid: ~p EpPid: ~p~n", [EpSupPid, EpPid]),
            {reply, {ok, EpPid}, store_endpoint(EpID, undefined, EpPid, State)}
    end;
handle_call({get_endpoint, EpID}, _From, State=#state{endpoints=EndPoints, endpoint_pool=PoolPid, sock=Socket}) ->
	case find_endpoint(EpID, EndPoints) of
		{ok, EpPid} ->
			{reply, {ok, EpPid}, State};
		undefined ->
		    case endpoint_sup_sup:start_endpoint(PoolPid, [Socket, EpID]) of
		        {ok, EpSupPid, EpPid} ->
		            {reply, {ok, EpPid}, store_endpoint(EpID, EpSupPid, EpPid, State)};
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
				{ok, EpSupPid, EpPid} -> 
					io:fwrite("start endpoint ~p~n", [EpID]),
					EpPid ! {datagram, Bin},
					{noreply, store_endpoint(EpID, EpSupPid, EpPid, State)};
				{error, _Reason} -> 
					io:fwrite("start_endpoint failed: ~p~n", [_Reason]),
					{noreply, State}
			end;
		undefined ->
			io:fwrite("client recv unexpected packet~n"),
			{noreply, State}
	end;
handle_info({'DOWN', Ref, process, _Pid, Reason}, State=#state{endpoints=EndPoints, endpoint_refs=EndPointsRefs, endpoint_pool=PoolPid}) ->
 	% Fun = fun(EpID, {_, EpSupPid, R}, _) when R == Ref ->  
 	% 	_ = case Reason of
 	% 		normal -> 
 	% 			endpoint_sup_sup:delete_endpoint(PoolPid, EpSupPid);
 	% 		_ -> 
 	% 			error_logger:error_msg("coap_endpoint ~p crashed~n", [EpID]), ok
 	% 	end,
 	% 	EpID;
 	% 	(_, _, Acc) -> Acc
 	% end,
 	% case maps:fold(Fun, undefined, EndPoints0) of
 	% 	undefined -> 
 	% 		{noreply, State};
 	% 	EpID ->
 	% 		{noreply, State#state{endpoints = maps:remove(EpID, EndPoints0)}}
 	% end;
 	case maps:get(Ref, EndPointsRefs, undefined) of
 		undefined ->	
 			{noreply, State};
 		{EpID, Pid} ->
 			case is_pid(PoolPid) of
 				true -> 
					ok = endpoint_sup_sup:delete_endpoint(PoolPid, Pid);
				false -> 
					ok
					%% Should we stop the relevant supervisor?
			end,
			error_logger:error_msg("coap_endpoint ~p stopped with reason ~p~n", [EpID, Reason]),
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

store_endpoint(EpID, EpSupPid, EpPid, State=#state{endpoints=EndPoints, endpoint_refs=EndPointsRefs}) ->
	Ref = erlang:monitor(process, EpPid),
	State#state{endpoints=maps:put(EpID, EpPid, EndPoints), endpoint_refs=maps:put(Ref, {EpID, EpSupPid}, EndPointsRefs)}.


