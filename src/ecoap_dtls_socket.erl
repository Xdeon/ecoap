-module(ecoap_dtls_socket).
-behaviour(gen_statem).
-behaviour(ecoap_socket).

%% API.
-export([start_link/4, connect/4, close/1, default_dtls_transopts/0]).
-export([get_endpoint/2, send/3]).

%% gen_statem.
-export([callback_mode/0]).
-export([init/1]).
-export([handle_event/4]).
-export([terminate/3]).
-export([code_change/4]).

%% state functions.
-export([accept/3, connected/3]).


-record(data, {
	lsocket = undefined :: undefined | ssl:sslsocket(),
	socket = undefined :: undefined | ssl:sslsocket(),
	server_name = undefined :: atom(),
	ep_id = undefined :: undefined | ecoap_endpoint:ecoap_endpoint_id(),
	endpoint_pid = undefined :: undefined | pid(),
	endpoint_sup_pid = undefined :: undefined | pid(),
	endpoint_ref = undefined :: undefined | reference(),
	timeout = undefined :: timeout(),
	protocol_config = undefined :: ecoap_config:protocol_config()
}).

-define(READ_PACKETS, 1000).
-define(ACTIVE_PACKETS, 100).

%% API.

-spec start_link(atom(), ssl:sslsocket(), map(), timeout()) -> {ok, pid()} | {error, term()}.
start_link(Name, ListenSocket, ProtoConfig, TimeOut) ->
	gen_statem:start_link(?MODULE, [accept, Name, ListenSocket, ProtoConfig, TimeOut], []).

-spec connect(ecoap_endpoint:endpoint_addr(), [ssl:connect_option()], map(), timeout()) -> {ok, pid()} | {error, term()}.
connect(EpAddr, TransOpts, ProtoConfig, TimeOut) ->
	gen_statem:start_link(?MODULE, [connect, EpAddr, TransOpts, ProtoConfig, TimeOut], []).

-spec get_endpoint(pid(), ecoap_endpoint:endpoint_addr()) -> {ok, pid()} | {error, term()}.
get_endpoint(Pid, EpAddr) ->
	gen_statem:call(Pid, {get_endpoint, EpAddr}).

-spec send(ssl:sslsocket(), ecoap_endpoint:ecoap_endpoint_id(), binary()) -> ok | {error, term()}.
send(Socket, _, Datagram) ->
    ssl:send(Socket, Datagram).

-spec close(pid()) -> ok.
close(Pid) ->
	gen_statem:stop(Pid).

-spec default_dtls_transopts() -> [ssl:connect_option()].
default_dtls_transopts() ->
	[binary, {active, false}, {reuseaddr, true}, {protocol, dtls}, {read_packets, ?READ_PACKETS}].

%% gen_statem.

callback_mode() ->
	state_functions.

init([accept, Name, ListenSocket, ProtoConfig0, TimeOut]) ->
	ProtoConfig = ecoap_config:merge_protocol_config(ProtoConfig0),
	StateData = #data{protocol_config=ProtoConfig, server_name=Name, lsocket=ListenSocket, timeout=TimeOut},
	{ok, accept, StateData, [{next_event, internal, accept}]};
init([connect, EpAddr={PeerIP, PeerPortNo}, TransOpts0, ProtoConfig0, TimeOut]) ->
	TransOpts = ecoap_config:merge_sock_opts(default_dtls_transopts(), TransOpts0),
	ProtoConfig = ecoap_config:merge_protocol_config(ProtoConfig0),
	case ssl:connect(PeerIP, PeerPortNo, TransOpts, TimeOut) of
		{ok, Socket} ->
			ok = ssl:setopts(Socket, [{active, ?ACTIVE_PACKETS}]),
			EpID = {{dtls, self()}, EpAddr},
			{ok, connected, #data{protocol_config=ProtoConfig, socket=Socket, ep_id=EpID, timeout=TimeOut}};
		{error, timeout} ->
			{stop, connect_timeout};
		{error, Reason} ->
			{stop, Reason}
	end.

accept(_, accept, StateData=#data{server_name=Name, lsocket=ListenSocket}) ->
	case ssl:transport_accept(ListenSocket) of
		{ok, CSocket} -> 
		    {ok, _} = ecoap_dtls_listener_sup:start_listener(Name),
			do_handshake(CSocket, StateData);
		{error, emfile} ->
			logger:log(warning, "DTLS acceptor reducing accept rate: out of file descriptors~n"),
			{keep_state_and_data, [{state_timeout, 100, accept}]};
		%% Exit if the listening socket got closed.
		{error, closed} ->
			{stop, closed};
		%% Continue otherwise.
		{error, _} ->
			{keep_state_and_data, [{next_event, internal, accept}]}
	end;
accept(EventType, EventData, _StateData) ->
	logger:log(error, "~p recvd unexpected event ~p in state ~p as ~p~n", [self(), {EventType, EventData}, ?FUNCTION_NAME, ?MODULE]),
	keep_state_and_data.

% client
connected({call, From}, {get_endpoint, EpAddr}, 
	StateData=#data{socket=Socket, ep_id=EpID={_, EpAddr}, server_name=undefined, endpoint_pid=undefined, endpoint_ref=undefined, protocol_config=ProtoConfig}) ->
	{ok, EpPid} = ecoap_endpoint:start_link(?MODULE, Socket, EpID, ProtoConfig),
	Ref = erlang:monitor(process, EpPid),
	{keep_state, StateData#data{endpoint_pid=EpPid, endpoint_ref=Ref}, [{reply, From, {ok, EpPid}}]};
% server
connected({call, From}, {get_endpoint, EpAddr}, 
	StateData=#data{socket=Socket, ep_id=EpID={_, EpAddr}, endpoint_pid=undefined, endpoint_ref=undefined, protocol_config=ProtoConfig}) ->
	{ok, EpSupPid, EpPid} = endpoint_sup:start_link([?MODULE, Socket, EpID, ProtoConfig]),
	Ref = erlang:monitor(process, EpPid),
	{keep_state, StateData#data{endpoint_pid=EpPid, endpoint_sup_pid=EpSupPid, endpoint_ref=Ref}, [{reply, From, {ok, EpPid}}]};
% in general
connected({call, From}, {get_endpoint, EpAddr}, #data{ep_id={_, EpAddr}, endpoint_pid=EpPid}) ->
	{keep_state_and_data, [{reply, From, {ok, EpPid}}]};
% this is illegal
connected({call, From}, {get_endpoint, _EpAddr}, _StateData) ->
	{keep_state_and_data, [{reply, From, {error, unmatched_endpoint_id}}]};
% ssl communication
connected(info, {ssl, Socket, Bin}, StateData=#data{socket=Socket, ep_id=EpID, endpoint_pid=undefined, protocol_config=ProtoConfig}) ->
	{ok, EpSupPid, EpPid} = endpoint_sup:start_link([?MODULE, Socket, EpID, ProtoConfig]),
	EpPid ! {datagram, Bin},
	Ref = erlang:monitor(process, EpPid),
	{keep_state, StateData#data{endpoint_pid=EpPid, endpoint_sup_pid=EpSupPid, endpoint_ref=Ref}};
connected(info, {ssl, Socket, Bin}, #data{socket=Socket, endpoint_pid=EpPid}) ->
	EpPid ! {datagram, Bin},
	keep_state_and_data;
connected(info, {ssl_passive, Socket}, #data{socket=Socket}) ->
	ok = ssl:setopts(Socket, [{active, ?ACTIVE_PACKETS}]),
	keep_state_and_data;
connected(info, {ssl_closed, Socket}, StateData=#data{socket=Socket}) ->
	% io:format("~p in ~p~n", [ssl_closed, self()]), 
    {stop, normal, StateData};
connected(info, {ssl_error, Socket, Reason}, StateData=#data{socket=Socket}) ->
	% io:format("~p in ~p~n", [ssl_error, self()]),
    {stop, {shutdown, Reason}, StateData};
% handle endpoint process down
connected(info, {'DOWN', Ref, process, _Pid, _Reason}, StateData=#data{endpoint_ref=Ref, endpoint_sup_pid=EpSupPid}) ->
	case is_pid(EpSupPid) of
		true -> 
			%% TODO: whether to terminate after endpoint process goes downn as a server? if not, when to?
			% server
			% gen_server:stop(EpSupPid),
			{stop, normal, StateData};
		false ->
			% client
			{keep_state, StateData#data{endpoint_pid=undefined, endpoint_ref=undefined, endpoint_sup_pid=undefined}}
	end;
connected(EventType, EventData, _StateData) ->
	logger:log(error, "~p recvd unexpected event ~p in state ~p as ~p~n", [self(), {EventType, EventData}, ?FUNCTION_NAME, ?MODULE]),
	keep_state_and_data.

handle_event(EventType, EventData, StateName, StateData) ->
	logger:log(error, "~p recvd unexpected event ~p in state ~p as ~p~n", [self(), {EventType, EventData}, StateName, ?MODULE]),
	{next_state, StateName, StateData}.

terminate(_Reason, _StateName, #data{socket=undefined}) ->
	ok;
terminate(_Reason, _StateName, #data{socket=Socket}) ->
	ssl:close(Socket).

code_change(_OldVsn, StateName, StateData, _Extra) ->
	{ok, StateName, StateData}.


%% Internal

do_handshake(CSocket, StateData=#data{timeout=TimeOut}) ->
	case ssl:handshake(CSocket, TimeOut) of
		{ok, Socket} -> 
			{ok, PeerAddr} = ssl:peername(Socket),
			ok = ssl:setopts(Socket, [{active, ?ACTIVE_PACKETS}]),
			{next_state, connected, StateData#data{socket=Socket, ep_id={{dtls, self()}, PeerAddr}}};
		{error, {tls_alert, _}} ->
			{stop, normal, StateData#data{socket=CSocket}};
		{error, Reason} when Reason =:= timeout; Reason =:= closed ->
			{stop, normal, StateData#data{socket=CSocket}};
		{error, Reason} ->
			{stop, Reason, StateData#data{socket=CSocket}}
	end.