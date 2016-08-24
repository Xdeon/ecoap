-module(ecoap_socket).
-behaviour(gen_server).

%% API.
-export([start_link/0, start_link/2, close/1]).

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
	sock = undefined :: inet:socket(),
	endpoints = undefined :: coap_endpoints(),
	endpoint_refs = undefined :: coap_endpoint_refs(),
	endpoint_pool = undefined :: undefined | pid()
}).

-opaque state() :: #state{}.
-export_type([state/0]).

-include("coap.hrl").

%% API.

-spec start_link() -> {ok, pid()}.
-spec start_link(pid(), inet:port_number()) -> {ok, pid()}.
%% client
start_link() ->
	gen_server:start_link(?MODULE, [0], []).
%% server
start_link(SupPid, InPort) when is_pid(SupPid) ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [SupPid, InPort], []).

%% client use
close(Pid) ->
	gen_server:cast(Pid, shutdown).

%% gen_server.

-spec init(_) -> {ok, state()}.
init([InPort]) ->
	% process_flag(trap_exit, true),
	case gen_udp:open(InPort, [binary, {active, false}, {reuseaddr, true}]) of
		{ok, Socket} ->
			error_logger:info_msg("coap listen on *:~p~n", [InPort]),
			{ok, #state{sock=Socket, endpoints=maps:new(), endpoint_refs=maps:new()}};
		{error, Reason} ->
			{stop, Reason}
	end;
init([SupPid, InPort]) ->
	self() ! {start_endpoint_sup_sup, SupPid, _MFA = {endpoint_sup, start_link, []}},
	init([InPort]).

-spec handle_call
  	(any(), from(), State) -> {reply, ignored, State} when State :: state().
handle_call(_Request, _From, State) ->
	{reply, ignored, State}.

-spec handle_cast
	(shutdown, State) -> {stop, normal, State} when State :: state().
handle_cast(shutdown, State) ->
	{stop, normal, State};
handle_cast(_Msg, State) ->
	{noreply, State}.

-spec handle_info
	({start_endpoint_sup_sup, pid(), {atom(), atom(), any()}}, State) -> {noreply, State};
	({udp, inet:socket(), inet:ip_address(), inet:port_number(), binary()}, State) -> {noreply, State}; 
	({'DOWN', reference(), process, pid(), any()}, State) -> {noreply, State} when State :: state().
handle_info({start_endpoint_sup_sup, SupPid, MFA}, State = #state{sock=Socket}) ->
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
			case endpoint_sup_sup:start_endpoint(PoolPid, [Socket, EpID]) of
				{ok, EpSupPid, EpPid} -> 
					io:fwrite("start endpoint ~p~n", [EpID]),
					EpPid ! {datagram, Bin},
					{noreply, store_endpoint(EpID, EpSupPid, EpPid, State)};
				{error, Reason} -> 
					io:fwrite("start_channel failed: ~p~n", [Reason]),
					{noreply, State}
			end;
		undefined ->
			io:fwrite("unexpected msg to socket?~n"),
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
 		{EpID, EpSupPid} when is_pid(EpSupPid) ->
 			_ = case Reason of
 				normal ->
 					endpoint_sup_sup:delete_endpoint(PoolPid, EpSupPid);
 				_ -> 
 					error_logger:error_msg("coap_endpoint ~p crashed~n", [EpID]), ok
 			end,
 			{noreply, State#state{endpoints=maps:remove(EpID, EndPoints), endpoint_refs=maps:remove(Ref, EndPointsRefs)}}
 	end;
handle_info(_Info, State) ->
	io:fwrite("ecoap_socket unexpected ~p~n", [_Info]),
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

