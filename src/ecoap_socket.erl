-module(ecoap_socket).
-behaviour(gen_server).

%% API.
-export([start_link/0, start_link/2]).

%% gen_server.
-export([init/1]).
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
	sock = undefined :: port(),
	endpoints = undefined :: coap_endpoints(),
	endpoint_pool = undefined :: undefined | pid()
}).

-opaque state() :: #state{}.
-export_type([state/0]).

-type coap_endpoints() :: map().
-export_type([coap_endpoints/0]).

%% API.

-spec start_link() -> {ok, pid()}.
-spec start_link(pid(), non_neg_integer()) -> {ok, pid()}.
%% client
start_link() ->
	gen_server:start_link(?MODULE, [0], []).
%% server
start_link(SupPid, InPort) when is_pid(SupPid) ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [SupPid, InPort], []).

%% gen_server.

-spec init(_) -> {ok, state()}.
init([InPort]) ->
	{ok, Socket} = gen_udp:open(InPort, [binary, {active, false}, {reuseaddr, true}]),
	error_logger:info_msg("coap listen on *:~p~n", [InPort]),
	{ok, #state{sock=Socket, endpoints=maps:new()}};
init([SupPid, InPort]) ->
	self() ! {start_endpoint_supervisor, SupPid, _MFA = {endpoint_sup, start_link, []}},
	init([InPort]).

-type from() :: {pid(), term()}.

-spec handle_call
  	(any(), from(), State) -> {reply, ignored, State} when State :: state().
handle_call(_Request, _From, State) ->
	{reply, ignored, State}.

-spec handle_cast
  	(any(), State) -> {noreply, State} when State :: state().
handle_cast(_Msg, State) ->
	{noreply, State}.

-spec handle_info
	({start_endpoint_supervisor, pid(), {atom(), atom(), any()}}, State) -> {noreply, State};
	({udp, _, _, _, binary()}, State) -> {noreply, State}; 
	({'DOWN', reference(), process, pid(), _}, State) -> {noreply, State} when State :: state().
handle_info({start_endpoint_supervisor, SupPid, MFA}, State = #state{sock=Socket}) ->
    {ok, Pid} = supervisor:start_child(SupPid, ?SPEC(MFA)),
    link(Pid),
    ok = inet:setopts(Socket, [{active, true}]),
    {noreply, State#state{endpoint_pool = Pid}};
handle_info({udp, Socket, PeerIP, PeerPortNo, Bin}, State=#state{sock=Socket, endpoints=EndPoints, endpoint_pool=PoolPid}) ->
	EpID = {PeerIP, PeerPortNo},
	case find_endpoint(EpID, EndPoints) of
		{ok, EpPid} -> 
			io:fwrite("found endpoint ~p~n", [EpID]),
			EpPid ! {datagram, Bin},
			{noreply, State};
		undefined when is_pid(PoolPid) -> 
			case supervisor:start_child(PoolPid, [Socket, EpID]) of
				{ok, EpSupPid, EpPid} -> 
					io:fwrite("start endpoint ~p~n", [EpID]),
					EpPid ! {datagram, Bin},
					{noreply, store_endpoint(EpID, EpSupPid, EpPid, State)};
				{error, Reason} -> 
					io:fwrite("start_channel failed: ~p~n", [Reason]),
					{noreply, State}
			end;
		undefined ->
			{noreply, State}
	end;
handle_info({'DOWN', Ref, process, _Pid, _}, State=#state{endpoints=EndPoints0, endpoint_pool=PoolPid}) ->
 	Fun = fun(EpID, {_, EpSupPid, R}, _) when R == Ref ->  
 		_ = supervisor:terminate_child(PoolPid, EpSupPid),
 		EpID;
 		(_, _, Acc) -> Acc
 	end,
 	case maps:fold(Fun, undefined, EndPoints0) of
 		undefined -> 
 			{noreply, State};
 		EpID ->
 			{noreply, State#state{endpoints = maps:remove(EpID, EndPoints0)}}
 	end;
handle_info(_Info, State) ->
	io:fwrite("ecoap_socket unexpected ~p~n", [_Info]),
	{noreply, State}.

terminate(_Reason, #state{sock=Socket}) ->
	gen_udp:close(Socket),
	ok.

-spec code_change(_, _, _) -> {ok, _}.
code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%% Internal   
-spec find_endpoint({_, _}, coap_endpoints()) -> undefined | {ok, pid()}. 
find_endpoint(EpID, EndPoints) ->
    case maps:find(EpID, EndPoints) of
        error -> undefined;
        {ok, {EpPid, _, _}} -> {ok, EpPid}
    end.

-spec store_endpoint({_, _}, pid(), pid(), state()) -> state().
store_endpoint(EpID, EpSupPid, EpPid, State=#state{endpoints=EndPoints}) ->
	Ref = erlang:monitor(process, EpPid),
	State#state{endpoints=maps:put(EpID, {EpPid, EpSupPid, Ref}, EndPoints)}.

