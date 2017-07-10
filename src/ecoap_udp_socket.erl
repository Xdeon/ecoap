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

-define(LOW_ACTIVE_PACKETS, 200).
-define(HIGH_ACTIVE_PACKETS, 400).

-define(DEFAULT_SOCK_OPTS,
	[binary, {active, ?LOW_ACTIVE_PACKETS}, {reuseaddr, true}]).

-record(state, {
	sock = undefined :: inet:socket(),
	endpoint_refs = #{} :: ecoap_endpoint_refs(),
	endpoint_pool = undefined :: undefined | pid()
}).

-opaque state() :: #state{}.
-type ecoap_endpoint_id() :: {inet:ip_address(), inet:port_number()}.
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
	{ok, #state{sock=Socket}}.

init(SupPid, InPort, Opts) ->
	{ok, State} = init([InPort, Opts]),
	error_logger:info_msg("coap listen on *:~p~n", [InPort]),
	register(?MODULE, self()),
	ok = proc_lib:init_ack({ok, self()}),
	{ok, Pid} = supervisor:start_child(SupPid, 
		#{id => endpoint_sup_sup,
      	  start =>{endpoint_sup_sup, start_link, []},
		  restart => temporary,
		  shutdown => infinity,
		  type => supervisor,
		  modules => [endpoint_sup_sup]}),
    link(Pid),
    gen_server:enter_loop(?MODULE, [], State#state{endpoint_pool=Pid}, {local, ?MODULE}).

% get an endpoint when being as a client
handle_call({get_endpoint, EpID}, _From, State=#state{sock=Socket, endpoint_pool=undefined}) ->
    case find_endpoint(EpID) of
    	{ok, EpPid} ->
    		{reply, {ok, EpPid}, State};
    	error ->
    		{ok, EpPid} = ecoap_endpoint:start_link(?MODULE, Socket, EpID),
    		store_endpoint(EpID, EpPid),
    		{reply, {ok, EpPid}, store_endpoint_monitor(EpID, EpPid, State)}
    end;
% get an endpoint when being as a server
handle_call({get_endpoint, EpID}, _From, State=#state{sock=Socket, endpoint_pool=PoolPid}) ->
	case find_endpoint(EpID) of
		{ok, EpPid} ->
			{reply, {ok, EpPid}, State};
		error ->
			case endpoint_sup_sup:start_endpoint(PoolPid, [?MODULE, Socket, EpID]) of
		        {ok, _, EpPid} ->
					store_endpoint(EpID, EpPid),
		            {reply, {ok, EpPid}, store_endpoint_monitor(EpID, EpPid, State)};
		        Error ->
		            {reply, Error, State}
		    end
	end;
% only for debug use
handle_call(get_all_endpoints, _From, State) ->
	EpPids = fetch_endpoint_pids(State),
	{reply, EpPids, State};
handle_call(_Request, _From, State) ->
	error_logger:error_msg("unexpected call ~p received by ~p as ~p~n", [_Request, self(), ?MODULE]),
	{noreply, State}.

handle_cast(shutdown, State) ->
	{stop, normal, State};
handle_cast(_Msg, State) ->
	error_logger:error_msg("unexpected cast ~p received by ~p as ~p~n", [_Msg, self(), ?MODULE]),
	{noreply, State}.

handle_info({udp, Socket, PeerIP, PeerPortNo, Bin}, State=#state{sock=Socket, endpoint_pool=PoolPid}) ->
	EpID = {PeerIP, PeerPortNo},
	case find_endpoint(EpID) of
		{ok, EpPid} ->
			EpPid ! {datagram, Bin},
			{noreply, State};
		error when is_pid(PoolPid) ->
			case endpoint_sup_sup:start_endpoint(PoolPid, [?MODULE, Socket, EpID]) of
				{ok, _, EpPid} -> 
					%io:fwrite("start endpoint ~p~n", [EpID]),
					EpPid ! {datagram, Bin},
					store_endpoint(EpID, EpPid),
					{noreply, store_endpoint_monitor(EpID, EpPid, State)};
				{error, _Reason} -> 
					%io:fwrite("start_endpoint failed: ~p~n", [_Reason]),
					{noreply, State}
			end;
		error ->
			% ignore unexpected message received by a client
			%io:fwrite("client recv unexpected packet~n"),
			{noreply, State}
	end;
handle_info({'DOWN', Ref, process, _Pid, _Reason}, State) ->
 	case find_endpoint_monitor(Ref, State) of
 		{ok, EpID} -> 
 			erase_endpoint(EpID),
 			{noreply, erase_endpoint_monitor(Ref, State)};
 		error -> 
 			{noreply, State}
 	end;
handle_info({udp_passive, Socket}, State=#state{sock=Socket, endpoint_refs=EndPointRefs}) ->
	Concurrency = maps:size(EndPointRefs),
	ActivePackets = if Concurrency < 2000 -> ?LOW_ACTIVE_PACKETS; 
					   true -> ?HIGH_ACTIVE_PACKETS 
					end,
	ok = inet:setopts(Socket, [{active, ActivePackets}]),
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

find_endpoint(EpID) ->
	case get(EpID) of
		undefined -> error;
		EpPid -> {ok, EpPid}
	end.

store_endpoint(EpID, EpPid) ->
	put(EpID, EpPid).

erase_endpoint(EpID) ->
	erase(EpID).

find_endpoint_monitor(Ref, #state{endpoint_refs=EndPointRefs}) ->
	maps:find(Ref, EndPointRefs).

store_endpoint_monitor(EpID, EpPid, State=#state{endpoint_refs=EndPointRefs}) ->
	State#state{endpoint_refs=maps:put(erlang:monitor(process, EpPid), EpID, EndPointRefs)}.

erase_endpoint_monitor(Ref, State=#state{endpoint_refs=EndPointRefs}) ->
	State#state{endpoint_refs=maps:remove(Ref, EndPointRefs)}.

fetch_endpoint_pids(#state{endpoint_refs=EndPointRefs}) ->
	[get(EpID) || EpID <- maps:values(EndPointRefs)].

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

store_endpoint_test() ->
	EpID = {{127,0,0,1}, 5683},
	store_endpoint(EpID, self()),
	State = store_endpoint_monitor(EpID, self(), #state{}),
	[Ref] = maps:keys(State#state.endpoint_refs),
	?assertEqual({ok, self()}, find_endpoint(EpID)),
	?assertEqual({ok, EpID}, find_endpoint_monitor(Ref, State)),
	?assertEqual([self()], fetch_endpoint_pids(State)),
	erase_endpoint(EpID),
	State1 = erase_endpoint_monitor(Ref, State),
	?assertEqual(error, find_endpoint(EpID)),
	?assertEqual(error, find_endpoint_monitor(Ref, State1)),
	?assertEqual([], fetch_endpoint_pids(State1)).

-endif.

