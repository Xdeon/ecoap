-module(ecoap_udp_socket).
-behaviour(gen_server).

%% API.
-export([start_link/0, start_link/3, close/1]).
-export([get_endpoint/2, get_all_endpoints/1]).
-export([send_datagram/3]).

%% gen_server.
-export([init/1]).
-export([init/3]).
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

-define(LOW_ACTIVE_PACKETS, 100).
-define(HIGH_ACTIVE_PACKETS, 300).

-define(DEFAULT_SOCK_OPTS,
	[binary, {active, ?LOW_ACTIVE_PACKETS}, {reuseaddr, true}]).

-record(state, {
	sock = undefined :: inet:socket(),
	endpoints = undefined :: ecoap_endpoints(),
	endpoints_cnt = undefined :: non_neg_integer(),
	endpoint_refs = undefined :: ecoap_endpoint_refs(),
	endpoint_pool = undefined :: undefined | pid()
}).

-opaque state() :: #state{}.
-type ecoap_endpoint_id() :: {inet:ip_address(), inet:port_number()}.
-type ecoap_endpoints() :: #{ecoap_endpoint_id() => pid()}.
-type ecoap_endpoint_refs() :: #{reference() => ecoap_endpoint_id()}.

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

%% module specific send function 
-spec send_datagram(inet:socket(), ecoap_udp_socket:ecoap_endpoint_id(), binary()) -> ok.
send_datagram(Socket, {PeerIP, PeerPortNo}, Datagram) ->
    inet_udp:send(Socket, PeerIP, PeerPortNo, Datagram).

%% gen_server.

init([InPort, Opts]) ->
	% process_flag(trap_exit, true),
	{ok, Socket} = gen_udp:open(InPort, merge_opts(?DEFAULT_SOCK_OPTS, Opts)),
	io:format("socket setting: ~p~n", [inet:getopts(Socket, [recbuf, sndbuf, buffer])]),
	{ok, #state{sock=Socket, endpoints=maps:new(), endpoints_cnt=0, endpoint_refs=maps:new()}}.

init(SupPid, InPort, Opts) ->
	{ok, State} = init([InPort, Opts]),
	error_logger:info_msg("coap listen on *:~p~n", [InPort]),
	register(?MODULE, self()),
	ok = proc_lib:init_ack({ok, self()}),
	{ok, Pid} = supervisor:start_child(SupPid, ?SPEC({endpoint_sup, start_link, []})),
    link(Pid),
    gen_server:enter_loop(?MODULE, [], State#state{endpoint_pool=Pid}, {local, ?MODULE}).

% get an endpoint when being as a client
handle_call({get_endpoint, EpID}, _From, State=#state{sock=Socket, endpoints=EndPoints, endpoint_pool=undefined}) ->
    case find_endpoint(EpID, EndPoints) of
        {ok, EpPid} ->
            {reply, {ok, EpPid}, State};
        error ->
            % {ok, EpSupPid, EpPid} = endpoint_sup:start_link(Socket, EpID),
            % %io:fwrite("EpSupPid: ~p EpPid: ~p~n", [EpSupPid, EpPid]),
            {ok, EpPid} = ecoap_endpoint:start_link(?MODULE, Socket, EpID),
            %io:fwrite("client started~n"),
            {reply, {ok, EpPid}, store_endpoint(EpID, EpPid, State)}
    end;
% get an endpoint when being as a server
handle_call({get_endpoint, EpID}, _From, State=#state{sock=Socket, endpoints=EndPoints, endpoint_pool=PoolPid}) ->
	case find_endpoint(EpID, EndPoints) of
		{ok, EpPid} ->
			{reply, {ok, EpPid}, State};
		error ->
		    case endpoint_sup_sup:start_endpoint(PoolPid, [?MODULE, Socket, EpID]) of
		        {ok, _, EpPid} ->
		            {reply, {ok, EpPid}, store_endpoint(EpID, EpPid, State)};
		        Error ->
		            {reply, Error, State}
		    end
    end;
% only for debug use
handle_call(get_all_endpoints, _From, State=#state{endpoints=EndPoints}) ->
	{reply, maps:values(EndPoints), State};
handle_call(_Request, _From, State) ->
	error_logger:error_msg("unexpected call ~p received by ~p as ~p~n", [_Request, self(), ?MODULE]),
	{noreply, State}.

handle_cast(shutdown, State) ->
	{stop, normal, State};
handle_cast(_Msg, State) ->
	error_logger:error_msg("unexpected cast ~p received by ~p as ~p~n", [_Msg, self(), ?MODULE]),
	{noreply, State}.

handle_info({udp, Socket, PeerIP, PeerPortNo, Bin}, State=#state{sock=Socket, endpoints=EndPoints, endpoint_pool=PoolPid}) ->
	EpID = {PeerIP, PeerPortNo},
	% ok = inet:setopts(Socket, [{active, once}]),
	case find_endpoint(EpID, EndPoints) of
		{ok, EpPid} -> 
			%io:fwrite("found endpoint ~p~n", [EpID]),
			EpPid ! {datagram, Bin},
			{noreply, State};
		error when is_pid(PoolPid) -> 
			case endpoint_sup_sup:start_endpoint(PoolPid, [?MODULE, Socket, EpID]) of
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
handle_info({'DOWN', Ref, process, _Pid, _Reason}, State=#state{endpoint_refs=EndPointsRefs}) ->
 	case find_endpoint_ref(Ref, EndPointsRefs) of
 		{ok, EpID} ->
 			{noreply, erase_endpoint(EpID, Ref, State)};
 		error ->	
 			{noreply, State}
 	end;
handle_info({udp_passive, Socket}, State=#state{sock=Socket, endpoints_cnt=EndPointsCnt}) ->
	ActivePackets = if EndPointsCnt < 1000 -> ?LOW_ACTIVE_PACKETS; true -> ?HIGH_ACTIVE_PACKETS end,
	ok = inet:setopts(Socket, [{active, ActivePackets}]),
	{noreply, State};

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

find_endpoint(EpID, EndPoints) ->
	maps:find(EpID, EndPoints).

find_endpoint_ref(Ref, EndPointsRefs) ->
	maps:find(Ref, EndPointsRefs).

store_endpoint(EpID, EpPid, State=#state{endpoints=EndPoints, endpoint_refs=EndPointsRefs, endpoints_cnt = EndPointsCnt}) ->
	Ref = erlang:monitor(process, EpPid),
	State#state{endpoints=maps:put(EpID, EpPid, EndPoints), 
				endpoint_refs=maps:put(Ref, EpID, EndPointsRefs), 
				endpoints_cnt=EndPointsCnt + 1}.

erase_endpoint(EpID, Ref, State=#state{endpoints=EndPoints, endpoint_refs=EndPointsRefs, endpoints_cnt = EndPointsCnt}) ->
	State#state{endpoints=maps:remove(EpID, EndPoints), 
				endpoint_refs=maps:remove(Ref, EndPointsRefs),
				endpoints_cnt=EndPointsCnt - 1}.

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

store_endpoint_test() ->
	EpID = {{127,0,0,1}, 5683},
	State = store_endpoint(EpID, self(), #state{endpoints=maps:new(), endpoint_refs=maps:new(), endpoints_cnt=0}),
	[Ref] = maps:keys(State#state.endpoint_refs),
	State1 = erase_endpoint(EpID, Ref, State),
	?assertEqual({ok, self()}, find_endpoint(EpID, State#state.endpoints)),
	?assertEqual({ok, EpID}, find_endpoint_ref(Ref, State#state.endpoint_refs)),
    ?assertEqual(error, find_endpoint(EpID, State1#state.endpoints)),
    ?assertEqual(error, find_endpoint_ref(Ref, State1#state.endpoint_refs)).

-endif.
