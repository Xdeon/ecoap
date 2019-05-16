-module(ecoap_client).
-behaviour(gen_server).

%% TODO: add support for configure request type
%% can be done by:
%% 1. change request API from multiple params to using a map of params
%% 2. specify request type in the map
%% 3. return {error, _} when synchronously sending a 'NON' request (which should be send asynchronously)

%% TODO:
%% 1. when server and client share socket, consider how to relate newly spawned client process to existing socket process
%% 2. do not realize 2 using explicit args cuz they are not always available, we may use EpID as a ref?
%%    say, instead of being {PeerIP, Port}, let it be something like {{Transport, SocketPid}, {PeerIP, Port}}?

%% TODO:
%% when message lifetime is set to value less than retransmit interval, 
%% it is possible that we never get a reply if using synchronous APIs with infinity timeout + the remote endpoint is unresponsive
%% this is because message exchange is cleaned up too early and the transmit timeout message leads to no where
%% however in this case we still have stale token info left in the endpoint process ...

%% API.
-export([open/2, open/3, close/1]).
-export([ping/1, ping/2]).
-export([
	discover/1, discover/2, discover_async/1,
	get/2, get/3, get/4, 
	put/3, put/4, put/5, 
	post/3, post/4, post/5, 
	delete/2, delete/3, delete/4, 
	fetch/4, fetch/5,
	patch/4, patch/5,
	ipatch/4, ipatch/5
	]).
-export([
	get_async/2, get_async/3, 
	put_async/3, put_async/4, 
	post_async/3, post_async/4, 
	delete_async/2, delete_async/3, 
	fetch_async/4,
	patch_async/4, 
	ipatch_async/4
	]).
-export([observe/2, observe/3, observe_and_wait_response/2, observe_and_wait_response/3, observe_and_wait_response/4]).
-export([unobserve/2, unobserve/3, unobserve_and_wait_response/2, unobserve_and_wait_response/3, unobserve_and_wait_response/4]).
-export([cancel_request/2]).
-export([flush/1]).
-export([get_remote_addr/1]).

-ifdef(TEST).
-export([get_reqrefs/1, get_obsregs/1, get_blockregs/1]).
-endif.

-export([start_link/3]).

%% gen_server.
-export([init/1]).
-export([handle_continue/2]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-record(state, {
	owner = undefined :: {reference(), pid()},
	client_opts = #{} :: client_opts(),
	socket = closed :: closed | {internal_socket | external_socket, module(), any()},
	socket_ref = undefined :: undefined | reference(),
	host = undefined :: undefined | binary(),
	ep_id = undefined :: undefined | ecoap_endpoint:ecoap_endpoint_id(),
	endpoint_pid = undefined :: undefined | pid(),
	requests = #{} :: #{reference() => request()},
	ongoing_blocks = #{} :: #{block_key() => reference()},
	observe_regs = #{} :: #{observe_key() => reference()},
	request_mapping = #{} :: #{reference() => reference()}
}).

-record(request, {
	method = undefined :: undefined | coap_message:coap_method(),
	options = #{} :: coap_message:optionset(), 
	content = <<>> :: binary(),
	origin_ref = undefined :: reference(),
	block_key = undefined :: undefined | block_key(),
	observe_key = undefined :: undefined | observe_key(),
	observe_seq = undefined :: undefined | non_neg_integer(),
	fragment = <<>> :: binary(), 
	reply_to = undefined :: pid() | {pid(), _}
}).

-type request() :: #request{}.

% block_key() :: {EpID, Path}
-type block_key() :: {ecoap_endpoint:ecoap_endpoint_id(), [binary()]}.

% observe_key() :: {EpID, Path, Accept}
-type observe_key() :: {ecoap_endpoint:ecoap_endpoint_id(), [binary()], atom() | non_neg_integer()}.

-type response() ::
	{ok, coap_message:success_code() | coap_message:error_code(), coap_content:coap_content()} |
	{error, _}.

-type observe_response() :: 
	{ok, reference(), pid(), non_neg_integer(), response()}.

-type client_opts() :: #{
	owner => pid(),
	protocol_config => map(),
	connect_timeout => timeout(),
	protocol => coap | coaps,
	transport => udp | dtls,
	transport_opts => [gen_udp:option()] | [ssl:connect_option()],
	external_socket => ecoap_socket:socket_id()
}.

-export_type([client_opts/0]).

%% API.
-spec open(inet:hostname() | inet:ip_address(), inet:port_number()) -> {ok, pid()} | {error, term()}.
open(Host, Port) ->
	open(Host, Port, #{}).

-spec open(inet:hostname() | inet:ip_address(), inet:port_number(), client_opts()) -> {ok, pid()} | {error, term()}.
open(Host, Port, ClientOpts=#{owner:=_}) when is_list(Host); is_atom(Host); is_tuple(Host) ->
	case check_options(ClientOpts) of
		ok -> start_link(Host, Port, ClientOpts);
		CheckError -> CheckError
	end;
open(Host, Port, ClientOpts) ->
	open(Host, Port, ClientOpts#{owner=>self()}).

-spec close(pid()) -> ok.
close(Pid) ->
	gen_server:stop(Pid).

check_options([]) ->
	ok;
check_options(ClientOpts) when is_map(ClientOpts) ->
	check_options(maps:to_list(ClientOpts));
check_options([{owner, Owner}|Opts]) when is_pid(Owner) ->
	check_options(Opts);
check_options([{connect_timeout, infinity}|Opts]) ->
	check_options(Opts);
check_options([{connect_timeout, TimeOut}|Opts]) when is_integer(TimeOut) ->
	check_options(Opts);
check_options([{protocol, Protocol}|Opts]) when Protocol =:= coap; Protocol =:= coaps ->
	check_options(Opts);
check_options([{transport, Transport}|Opts]) when Transport =:= udp; Transport =:= dtls ->
	check_options(Opts);
check_options([{transport_opts, TransOpts}|Opts]) when is_list(TransOpts) ->
	check_options(Opts);
check_options([{protocol_config, Config}|Opts]) when is_map(Config) ->
	check_options(Opts);
check_options([{external_socket, {Transport, Socket}}|Opts]) 
	when (Transport =:= udp orelse Transport =:= dtls) 
	andalso (is_pid(Socket) orelse is_atom(Socket) orelse is_tuple(Socket)) ->
	check_options(Opts);
check_options([Opt|_]) ->
	{error, {client_options, Opt}}.

-spec ping(pid()) -> ok | {error, _}.
ping(Pid) ->
	ping(Pid, infinity).

-spec ping(pid(), timeout()) -> ok | {error, _}.
ping(Pid, TimeOut) ->
	case gen_server:call(Pid, {command, ping}, TimeOut) of
		{error, 'RST'} -> ok;
		Else -> Else
	end.

-spec discover(pid()) -> response().
discover(Pid) ->
	discover(Pid, infinity).

-spec discover(pid(), timeout()) -> response() | no_return().
discover(Pid, TimeOut) ->
	get(Pid, <<"/.well-known/core">>, #{}, TimeOut).

-spec discover_async(pid()) -> {ok, reference()}.
discover_async(Pid) ->
	get_async(Pid, <<"/.well-known/core">>).

-spec get(pid(), iodata()) -> response().
get(Pid, Uri) ->
	request(Pid, 'GET', Uri, <<>>, #{}, infinity).

-spec get(pid(), iodata(), coap_message:optionset()) -> response().
get(Pid, Uri, Options) ->
	request(Pid, 'GET', Uri, <<>>, Options, infinity).

-spec get(pid(), iodata(), coap_message:optionset(), non_neg_integer() | infinity) -> response() | no_return().
get(Pid, Uri, Options, TimeOut) ->
	request(Pid, 'GET', Uri, <<>>, Options, TimeOut).

-spec get_async(pid(), iodata()) -> {ok, reference()}.
get_async(Pid, Uri) ->
	request_async(Pid, 'GET', Uri, <<>>, #{}).

-spec get_async(pid(), iodata(), coap_message:optionset()) -> {ok, reference()}.
get_async(Pid, Uri, Options) ->
	request_async(Pid, 'GET', Uri, <<>>, Options).

-spec put(pid(), iodata(), binary()) -> response().
put(Pid, Uri, Content) ->
	request(Pid, 'PUT', Uri, Content, #{}, infinity).

-spec put(pid(), iodata(), binary(), coap_message:optionset()) -> response().
put(Pid, Uri, Content, Options) ->
	request(Pid, 'PUT', Uri, Content, Options, infinity).

-spec put(pid(), iodata(), binary(), coap_message:optionset(), non_neg_integer() | infinity) -> response() | no_return().
put(Pid, Uri, Content, Options, TimeOut) ->
	request(Pid, 'PUT', Uri, Content, Options, TimeOut).

-spec put_async(pid(), iodata(), binary()) -> {ok, reference()}.
put_async(Pid, Uri, Content) ->
	request_async(Pid, 'PUT', Uri, Content, #{}).

-spec put_async(pid(), iodata(), binary(), coap_message:optionset()) -> {ok, reference()}.
put_async(Pid, Uri, Content, Options) ->
	request_async(Pid, 'PUT', Uri, Content, Options).

-spec post(pid(), iodata(), binary()) -> response().
post(Pid, Uri, Content) ->
	request(Pid, 'POST', Uri, Content, #{}, infinity).

-spec post(pid(), iodata(), binary(), coap_message:optionset()) -> response().
post(Pid, Uri, Content, Options) ->
	request(Pid, 'POST', Uri, Content, Options, infinity).

-spec post(pid(), iodata(), binary(), coap_message:optionset(), non_neg_integer() | infinity) -> response() | no_return().
post(Pid, Uri, Content, Options, TimeOut) ->
	request(Pid, 'POST', Uri, Content, Options, TimeOut).

-spec post_async(pid(), iodata(), binary()) -> {ok, reference()}.
post_async(Pid, Uri, Content) ->
	request_async(Pid, 'POST', Uri, Content, #{}).

-spec post_async(pid(), iodata(), binary(), coap_message:optionset()) -> {ok, reference()}.
post_async(Pid, Uri, Content, Options) ->
	request_async(Pid, 'POST', Uri, Content, Options).

-spec delete(pid(), iodata()) -> response().
delete(Pid, Uri) ->
	request(Pid, 'DELETE', Uri, <<>>, #{}, infinity).

-spec delete(pid(), iodata(), coap_message:optionset()) -> response().
delete(Pid, Uri, Options) ->
	request(Pid, 'DELETE', Uri, <<>>, Options, infinity).

-spec delete(pid(), iodata(), coap_message:optionset(), non_neg_integer() | infinity) -> response() | no_return().
delete(Pid, Uri, Options, TimeOut) ->
	request(Pid, 'DELETE', Uri, <<>>, Options, TimeOut).

-spec delete_async(pid(), iodata()) -> {ok, reference()}.
delete_async(Pid, Uri) ->
	request_async(Pid, 'DELETE', Uri, <<>>, #{}).

-spec delete_async(pid(), iodata(), coap_message:optionset()) -> {ok, reference()}.
delete_async(Pid, Uri, Options) ->
	request_async(Pid, 'DELETE', Uri, <<>>, Options).

-spec fetch(pid(), iodata(), binary(), coap_message:optionset()) -> response().
fetch(Pid, Uri, Content, Options) ->
	request(Pid, 'FETCH', Uri, Content, Options, infinity).

-spec fetch(pid(), iodata(), binary(), coap_message:optionset(), non_neg_integer() | infinity) -> response() | no_return().
fetch(Pid, Uri, Content, Options, TimeOut) ->
	request(Pid, 'FETCH', Uri, Content, Options, TimeOut).

-spec fetch_async(pid(), iodata(), binary(), coap_message:optionset()) -> {ok, reference()}.
fetch_async(Pid, Uri, Content, Options) ->
	request_async(Pid, 'FETCH', Uri, Content, Options).

-spec patch(pid(), iodata(), binary(), coap_message:optionset()) -> response().
patch(Pid, Uri, Content, Options) ->
	request(Pid, 'PATCH', Uri, Content, Options, infinity).

-spec patch(pid(), iodata(), binary(), coap_message:optionset(), non_neg_integer() | infinity) -> response() | no_return().
patch(Pid, Uri, Content, Options, TimeOut) ->
	request(Pid, 'PATCH', Uri, Content, Options, TimeOut).

-spec patch_async(pid(), iodata(), binary(), coap_message:optionset()) -> {ok, reference()}.
patch_async(Pid, Uri, Content, Options) ->
	request_async(Pid, 'PATCH', Uri, Content, Options).

-spec ipatch(pid(), iodata(), binary(), coap_message:optionset()) -> response().
ipatch(Pid, Uri, Content, Options) ->
	request(Pid, 'iPATCH', Uri, Content, Options, infinity).

-spec ipatch(pid(), iodata(), binary(), coap_message:optionset(), non_neg_integer() | infinity) -> response().
ipatch(Pid, Uri, Content, Options, TimeOut) ->
	request(Pid, 'iPATCH', Uri, Content, Options, TimeOut).

-spec ipatch_async(pid(), iodata(), binary(), coap_message:optionset()) -> {ok, reference()}.
ipatch_async(Pid, Uri, Content, Options) ->
	request_async(Pid, 'iPATCH', Uri, Content, Options).

-spec request(pid(), coap_message:coap_method(), iodata(), binary(), coap_message:optionset(), non_neg_integer() | infinity) -> response() | no_return().
request(Pid, Method, Uri, Content, Options, TimeOut) ->
	gen_server:call(Pid, {command, {request, sync, Method, Uri, Content, Options}}, TimeOut).

-spec request_async(pid(), coap_message:coap_method(), iodata(), binary(), coap_message:optionset()) -> {ok, reference()}.
request_async(Pid, Method, Uri, Content, Options) ->
	gen_server:call(Pid, {command, {request, async, Method, Uri, Content, Options}}).

-spec cancel_request(pid(), reference()) -> ok.
cancel_request(Pid, Ref) ->
	gen_server:call(Pid, {command, {cancel_request, Ref}}).

-spec observe(pid(), iodata()) -> {ok, reference()}.
observe(Pid, Uri) ->
	observe(Pid, Uri, #{}).

-spec observe(pid(), iodata(), coap_message:optionset()) -> {ok, reference()}.
observe(Pid, Uri, Options) ->
	gen_server:call(Pid, {command, {observe, Uri, Options}}).

-spec observe_and_wait_response(pid(), iodata()) -> observe_response() | response().
observe_and_wait_response(Pid, Uri) ->
	observe_and_wait_response(Pid, Uri, #{}, infinity).

-spec observe_and_wait_response(pid(), iodata(), coap_message:optionset()) -> observe_response() | response().
observe_and_wait_response(Pid, Uri, Options) ->
	observe_and_wait_response(Pid, Uri, Options, infinity).

-spec observe_and_wait_response(pid(), iodata(), coap_message:optionset(), non_neg_integer() | infinity) -> observe_response() | response() | no_return().
observe_and_wait_response(Pid, Uri, Options, TimeOut) ->
	{ok, Ref} = observe(Pid, Uri, Options),
	MonitorRef = erlang:monitor(process, Pid),
	receive 
		{coap_notify, Ref, Pid2, ObsSeq, Response} ->
			demonitor(MonitorRef, [flush]),
			{ok, Ref, Pid2, ObsSeq, Response};
		{coap_response, Ref, _Pid, Response} ->
			demonitor(MonitorRef, [flush]),
			Response;
		{'DOWN', MonitorRef, process, Pid, noconnection} ->
			exit({nodedown, node(Pid)});
		{'DOWN', MonitorRef, process, Pid, Reason} ->
			exit(Reason)
	after TimeOut ->
		demonitor(MonitorRef, [flush]),
		exit(timeout)
	end.	

-spec unobserve(pid(), reference()) -> {ok, reference()}.
unobserve(Pid, Ref) ->
	unobserve(Pid, Ref, []).

-spec unobserve(pid(), reference(), [binary()]) -> {ok, reference()}.
unobserve(Pid, Ref, ETag) ->
	gen_server:call(Pid, {command, {unobserve, Ref, ETag}}).

-spec unobserve_and_wait_response(pid(), reference()) -> response().
unobserve_and_wait_response(Pid, Ref) ->
	unobserve_and_wait_response(Pid, Ref, [], infinity).

-spec unobserve_and_wait_response(pid(), reference(), [binary()]) -> response().
unobserve_and_wait_response(Pid, Ref, ETag) ->
	unobserve_and_wait_response(Pid, Ref, ETag, infinity).

-spec unobserve_and_wait_response(pid(), reference(), [binary()], non_neg_integer() | infinity) -> response() | no_return().
unobserve_and_wait_response(Pid, Ref, ETag, TimeOut) ->
	{ok, Ref2} = unobserve(Pid, Ref, ETag),
	MonitorRef = erlang:monitor(process, Pid),
	receive 
		{coap_response, Ref2, _Pid, Response} ->
			demonitor(MonitorRef, [flush]),
			Response;
		{'DOWN', MonitorRef, process, Pid, noconnection} ->
			exit({nodedown, node(Pid)});
		{'DOWN', MonitorRef, process, Pid, Reason} ->
			exit(Reason)
	after TimeOut ->
		demonitor(MonitorRef, [flush]),
		exit(timeout)
	end.

-spec flush(pid() | reference()) -> ok.
flush(Pid) when is_pid(Pid) ->
	flush_pid(Pid);
flush(Ref) ->
	flush_ref(Ref).

flush_ref(Ref) ->
	receive 	
		{coap_response, Ref, _Pid, _Response} ->
			flush_ref(Ref);
		{coap_notify, Ref, _Pid, _ObsSeq, _Response} ->
			flush_ref(Ref)
	after 0 ->
		ok
	end.

flush_pid(Pid) ->
	receive
		{coap_response, _Ref, Pid, _Response} ->
			flush_pid(Pid);
		{coap_notify, _Ref, Pid, _ObsSeq, _Response} ->
			flush_pid(Pid);
		{'DOWN',  _, process, Pid, _} ->
			flush_pid(Pid)
	after 0 ->
		ok
	end.

-spec get_remote_addr(pid()) -> {ok, {binary() | undefined, tuple()}}.
get_remote_addr(Pid) ->
	gen_server:call(Pid, get_remote_addr).

-spec start_link(inet:hostname() | inet:ip_adress(), inet:port_number(), client_opts()) -> {ok, pid()} | {error, term()}.
start_link(Host, Port, ClientOpts) ->
	gen_server:start_link(?MODULE, [Host, Port, ClientOpts], []).

-ifdef(TEST).

% utility function for test purpose
-spec get_reqrefs(pid()) -> map().
get_reqrefs(Pid) -> gen_server:call(Pid, get_reqrefs).

-spec get_obsregs(pid()) -> map().
get_obsregs(Pid) -> gen_server:call(Pid, get_obsregs).

-spec get_blockregs(pid()) -> map().
get_blockregs(Pid) -> gen_server:call(Pid, get_blockregs).

-endif.

%% gen_server.

init([Host, Port, ClientOpts=#{owner:=Owner}]) ->
	process_flag(trap_exit, true),
	OwnerRef = erlang:monitor(process, Owner),
	State = #state{owner={OwnerRef, Owner}, client_opts=ClientOpts},
	case maps:find(external_socket, ClientOpts) of
		{ok, {RawTransport, Socket}} ->
			Transport = ecoap_socket:transport_module(RawTransport),
			{ok, State#state{socket={external_socket, Transport, Socket}}, {continue, {resolve, RawTransport, Host, Port}}};
		error ->
			RawTransport = maps:get(transport, ClientOpts, ecoap_uri:default_transport(Port)),
			{ok, State, {continue, {connect, RawTransport, Host, Port}}}
	end.

handle_continue({resolve, RawTransport, Host0, Port}, State=#state{socket={_, _, Socket}}) ->
	case ecoap_uri:get_peer_addr(Host0) of
		{ok, Host, IP} ->
			SocketRef = erlang:monitor(process, Socket),
			EpID = {{RawTransport, Socket}, {IP, Port}},
			{noreply, State#state{host=Host, ep_id=EpID, socket_ref=SocketRef}};
		Other ->
			{stop, {shutdown, Other}, State}
	end;
handle_continue({connect, RawTransport, Host0, Port}, State) ->
	Transport = ecoap_socket:transport_module(RawTransport),
	case ecoap_uri:get_peer_addr(Host0) of
		{ok, Host, IP} ->
			start_connection(RawTransport, Transport, {IP, Port}, State#state{host=Host});
		Other ->	
			{stop, {shutdown, Other}, State}
	end.

start_connection(RawTransport, Transport, EpAddr, State=#state{client_opts=ClientOpts}) ->
	TransOpts = maps:get(transport_opts, ClientOpts, []),
	TimeOut = maps:get(connect_timeout, ClientOpts, 5000),
	ProtoConfig = maps:get(protocol_config, ClientOpts, #{}),
	case Transport:connect(EpAddr, TransOpts, ProtoConfig, TimeOut) of
		{ok, Socket} -> 
			SocketRef = erlang:monitor(process, Socket),
			EpID = {{RawTransport, Socket}, EpAddr},
			{noreply, State#state{socket={internal_socket, Transport, Socket}, ep_id=EpID, socket_ref=SocketRef}};
		Other ->
			{stop, {shutdown, Other}, State}
	end.

% assume endpoint process will not terminate when everything goes fine and termination only means crash
handle_call({command, Command}, From, State=#state{endpoint_pid=undefined, ep_id={_, EpAddr}, socket={_, Transport, SocketPid}}) ->
	{ok, EndpointPid} = Transport:get_endpoint(SocketPid, EpAddr),
	link(EndpointPid),
	handle_command(Command, From, State#state{endpoint_pid=EndpointPid});
handle_call({command, Command}, From, State) ->
	handle_command(Command, From, State);
% FOR TEST USE
handle_call(get_reqrefs, _From, State=#state{requests=Requests}) ->
	{reply, Requests, State};
handle_call(get_blockregs, _From, State=#state{ongoing_blocks=OngoingBlocks}) ->
	{reply, OngoingBlocks, State};
handle_call(get_obsregs, _From, State=#state{observe_regs=ObsRegs}) ->
	{reply, ObsRegs, State};
% END FOR TEST USE
handle_call(_Request, _From, State) ->
	{noreply, State}.

handle_command(ping, {Pid, _}=From, State=#state{endpoint_pid=EndpointPid, requests=Requests}) ->
	{ok, Ref} = ecoap_endpoint:ping(EndpointPid, erlang:monitor(process, Pid)),
	Request = #request{method=undefined, origin_ref=Ref, reply_to=From},
	{noreply, State#state{requests=maps:put(Ref, Request, Requests)}};
handle_command({request, Sync, Method, Uri, Content, Options}, {Pid, _}=From, State=#state{endpoint_pid=EndpointPid, requests=Requests, host=Host, ep_id=EpID}) ->
	Options2 = make_options(Host, EpID, Uri, Options),
	{ok, Ref} = request_block1(EndpointPid, erlang:monitor(process, Pid), Method, Options2, Content),
	case Sync of
		sync ->
			Request = #request{method=Method, options=Options2, content=Content, origin_ref=Ref, reply_to=From},
			{noreply, State#state{requests=maps:put(Ref, Request, Requests)}};
		async ->
			Request = #request{method=Method, options=Options2, content=Content, origin_ref=Ref, reply_to=Pid},
			{reply, {ok, Ref}, State#state{requests=maps:put(Ref, Request, Requests)}}
	end;
handle_command({observe, Uri, Options}, {Pid, _}, State=#state{endpoint_pid=EndpointPid, requests=Requests, observe_regs=ObsRegs, host=Host, ep_id=EpID}) ->
	#{path:=Path} = ecoap_uri:get_uri_parms(Uri),
	Options2 = make_options(Host, EpID, Uri, Options),
	ObsKey = {EpID, Path, coap_message:get_option('Accept', Options2)},
	Ref = case maps:find(ObsKey, ObsRegs) of 
		{ok, OldRef} -> OldRef;
		error -> erlang:monitor(process, Pid)
	end,
	{ok, Ref} = ecoap_endpoint:send_request(EndpointPid, Ref, 
				ecoap_request:request('CON', 'GET', coap_message:add_option('Observe', 0, Options2))),
	Request = #request{method='GET', options=Options2, origin_ref=Ref, reply_to=Pid, observe_key=ObsKey},
	Requests2 = maps:put(Ref, Request, Requests),
	ObsRegs2 = maps:put(ObsKey, Ref, ObsRegs),
	{reply, {ok, Ref}, State#state{requests=Requests2, observe_regs=ObsRegs2}};
handle_command({unobserve, Ref, ETag}, {Pid, _}, 
	State=#state{endpoint_pid=EndpointPid, requests=Requests, request_mapping=RequestMapping, observe_regs=ObsRegs}) ->
	case maps:find(Ref, Requests) of
		error ->
			{reply, {error, no_observe}, State};
		{ok, #request{observe_key=undefined}} ->
			{reply, {error, no_observe}, State};
		{ok, #request{options=Options, observe_key=ObsKey} = Request} ->
			Ref = maps:get(ObsKey, ObsRegs),
			Options2 = coap_message:add_option('ETag', ETag, Options),
			{ok, Ref} = ecoap_endpoint:send_request(EndpointPid, Ref,
							ecoap_request:request('CON', 'GET', coap_message:add_option('Observe', 1, Options2))),
			Request2 = Request#request{options=Options2, origin_ref=Ref, reply_to=Pid}, 
			State2 = check_and_cancel_request(maps:get(Ref, RequestMapping, undefined), State),
			{reply, {ok, Ref},  State2#state{requests=maps:put(Ref, Request2, Requests)}}
	end;
handle_command({cancel_request, Ref}, _From, State) ->
	{reply, ok, check_and_cancel_request(Ref, State)};
handle_command(get_remote_addr, _From, State=#state{host=Host, ep_id=EpID}) ->
	{reply, {ok, Host, EpID}, State}.

handle_cast(_Msg, State) ->
	{noreply, State}.

handle_info({coap_response, EpID, EndpointPid, Ref, Message}, State=#state{requests=Requests}) ->
	case maps:find(Ref, Requests) of
		error -> 
			{noreply, State};
		{ok, Request} ->
			case ecoap_request:requires_ack(Message) of
				true -> {ok, _} = ecoap_endpoint:send(EndpointPid, ecoap_request:ack(Message)), ok;
				false -> ok
			end,
			case coap_message:get_code(Message) of
				{ok, 'Continue'} ->
					handle_upload(EpID, EndpointPid, Ref, Request, Message, State);
				{ok, _Code} ->
					handle_download(EpID, EndpointPid, Ref, Request, Message, State);
				{error, _Code} ->
					handle_error(Ref, Request, {coap_response, Message}, State)
			end
	end;
handle_info({coap_error, _EpID, _EndpointPid, Ref, Error}, State=#state{requests=Requests}) ->
	case maps:find(Ref, Requests) of
		error -> 
			{noreply, State};
		{ok, Request} ->
			handle_error(Ref, Request, {coap_error, Error}, State)
	end;
handle_info({coap_ack, _EpID, _EndpointPid, Ref}, State=#state{requests=Requests}) ->
	case maps:find(Ref, Requests) of
		{ok, #request{} = Request} ->
			send_response(Request, {separate, Ref}),
			Requests2 = maps:put(Ref, separate(Request), Requests),
			{noreply, State#state{requests=Requests2}};
		error -> 
			{noreply, State}
	end;
handle_info({'DOWN', Ref, process, Owner, Reason}, State=#state{owner={Ref, Owner}}) ->
	{stop, {shutdown, Reason}, State};
handle_info({'DOWN', Ref, process, _Pid, Reason}, State=#state{socket_ref=Ref}) ->
	{stop, {shutdown, Reason}, State#state{socket=closed}};
handle_info({'DOWN', Ref, process, _Pid, _Reason}, State=#state{requests=Requests}) ->
	case maps:find(Ref, Requests) of
		{ok, #request{origin_ref=OriginRef}} ->
			{noreply, check_and_cancel_request(OriginRef, State)};
		error ->
			{noreply, State}
	end;
handle_info({'EXIT', Pid, Reason}, State=#state{endpoint_pid=Pid}) ->
	{stop, {shutdown, Reason}, State};
handle_info(_Info, State) ->
	{noreply, State}.

terminate(_Reason, #state{socket={internal_socket, Transport, Socket}}) ->
	Transport:close(Socket);
terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%% Internal
handle_upload(EpID, EndpointPid, Ref, Request, Message, 
	State=#state{requests=Requests, ongoing_blocks=OngoingBlocks, request_mapping=RequestMapping}) ->
	#request{method=Method, options=RequestOptions, content=Content, origin_ref=OriginRef, reply_to=ReplyTo} = Request,
	{Num, true, Size} = coap_message:get_option('Block1', Message),
	{ok, Ref2} = request_block1(EndpointPid, make_reference(ReplyTo), Method, RequestOptions, {Num+1, false, Size}, Content),
	% store ongoing block1 transfer
	BlockKey = {EpID, coap_message:get_option('Uri-Path', RequestOptions)},
	{Requests2, RequestMapping2} = maybe_cancel_ongoing_blocks(EndpointPid, BlockKey, Ref, OngoingBlocks, Requests, RequestMapping),
	OngoingBlocks2 = maps:put(BlockKey, Ref2, OngoingBlocks),
	% update request mapping
	RequestMapping3 = maps:put(OriginRef, Ref2, RequestMapping2),
	Requests3 = maps:put(Ref2, Request#request{block_key=BlockKey}, remove_request(Ref, Requests2)),
	{noreply, State#state{requests=Requests3, ongoing_blocks=OngoingBlocks2, request_mapping=RequestMapping3}}.

handle_download(EpID, EndpointPid, Ref, Request, Message, 
	State=#state{requests=Requests, ongoing_blocks=OngoingBlocks, request_mapping=RequestMapping, observe_regs=ObsRegs}) ->
	#request{method=Method, options=RequestOptions, origin_ref=OriginRef, 
		fragment=Fragment, observe_seq=Seq, observe_key=ObsKey, reply_to=ReplyTo} = Request,
	Data = coap_message:get_payload(Message),
	% block key is generated based on resource uri
	BlockKey = {EpID, coap_message:get_option('Uri-Path', RequestOptions)},
	% cancel ongoing blockwise transfer with same resource, if any
	{Requests2, RequestMapping2} = maybe_cancel_ongoing_blocks(EndpointPid, BlockKey, Ref, OngoingBlocks, Requests, RequestMapping),
	% observe sequence number only exists in single notification or first block of a notification
	ObsSeq = coap_message:get_option('Observe', Message, Seq),
	case coap_message:get_option('Block2', Message) of
		{Num, true, Size} ->
			% more blocks follow, ask for more
            % no payload for requests with Block2 with NUM != 0
            {ok, Ref2} = request_block2(EndpointPid, make_reference(ReplyTo), Method, RequestOptions, {Num+1, false, Size}),
            % store ongoing block2 transfer
			OngoingBlocks2 = maps:put(BlockKey, Ref2, OngoingBlocks),
            Request2 = Request#request{block_key=BlockKey, observe_seq=ObsSeq, fragment= <<Fragment/binary, Data/binary>>},
            {Requests3, ObsRegs2} = case is_observe(ObsSeq, ObsKey) of
            	false -> 
            		% not an observe notification, update requests record and clean observe reg
            		{maps:put(Ref2, Request2, remove_request(Ref, Requests2)), maps:remove(ObsKey, ObsRegs)};
            	true ->               
            		case Ref of
            			OriginRef ->
            				% first block of an observe notification, update requests record but do not remove origin request
            				{maps:put(Ref2, Request2, Requests2), ObsRegs};
            			_ ->
            				% following block of an observe notification, update requests record
            				{maps:put(Ref2, Request2, remove_request(Ref, Requests2)), ObsRegs}
            		end
            end,
            % update request mapping
            RequestMapping3 = maps:put(OriginRef, Ref2, RequestMapping2),
            {noreply, State#state{requests=Requests3, ongoing_blocks=OngoingBlocks2, 
            						request_mapping=RequestMapping3, observe_regs=ObsRegs2}};
        _Else ->
        	% not segmented or all blocks received
			Response = return_response(coap_message:set_payload(<<Fragment/binary, Data/binary>>, Message)),
			send_response(Request#request{observe_seq=ObsSeq}, Response),
			% clean ongoing block2 transfer, if any
			OngoingBlocks2 = maps:remove(BlockKey, OngoingBlocks),
			{Requests3, ObsRegs2} = case is_observe(ObsSeq, ObsKey) of
				false -> 
					% not an observe notification, clean all state including observe registry
					{remove_request(Ref, Requests2), maps:remove(ObsKey, ObsRegs)};
				true ->
					case Ref of 
						OriginRef -> 
							% an observe notification not segmented, keep origin request 
							{Requests2, ObsRegs};
						_ ->
							% all blocks of an observe notification received, clean last block reference
							{remove_request(Ref, Requests2), ObsRegs}
					end
			end,
			% clean request mapping
			RequestMapping3 = maps:remove(OriginRef, RequestMapping2),
			{noreply, State#state{requests=Requests3, ongoing_blocks=OngoingBlocks2, 
									request_mapping=RequestMapping3, observe_regs=ObsRegs2}}
	end.

handle_error(Ref, Request, Error, 
	State=#state{requests=Requests, ongoing_blocks=OngoingBlocks, request_mapping=RequestMapping, observe_regs=ObsRegs}) ->
	#request{origin_ref=OriginRef, block_key=BlockKey, observe_key=ObsKey} = Request,
	Response = case Error of 
		{coap_error, Reason} -> {error, Reason};
		{coap_response, Message} -> return_response(Message)
	end,
	send_response(Request, Response),
	RequestMapping2 = maps:remove(OriginRef, RequestMapping),
	Requests2 = maps:remove(Ref, maps:remove(OriginRef, Requests)),
	OngoingBlocks2 = maps:remove(BlockKey, OngoingBlocks),
	ObsRegs2 = maps:remove(ObsKey, ObsRegs),
	{noreply, State#state{requests=Requests2, ongoing_blocks=OngoingBlocks2, 
							request_mapping=RequestMapping2, observe_regs=ObsRegs2}}.

make_options(Host, EpID, Uri, Options) ->
	PortNo = ecoap_endpoint:get_peer_info(port, EpID),
	#{path:=Path, 'query':=Query} = ecoap_uri:get_uri_parms(Uri),
	coap_message:add_option('Uri-Host', Host, 
		coap_message:add_option('Uri-Port', PortNo, Options#{'Uri-Path'=>Path, 'Uri-Query'=>Query})).

% this is problemtic
% one thought: make make_new_request in ecoap_endpoint.erl trigger a flag which makes the process not terminate itself on purge
% and handle_info({'EXIT', ClientPid, _}, State) will turn off this flag and the endpoint process (if still alive) purge as usual
% another: make ecoap_client monitor endpoint process and retry on 'DOWN'
% get_endpoint(Socket={_, Transport, SocketPid}, EpID) ->
% 	{ok, EndpointPid} = Transport:get_endpoint(SocketPid, EpID),
% 	try link(EndpointPid) of
% 		true -> {ok, EndpointPid}
% 	catch error:noproc -> 
% 		get_endpoint(Socket, EpID)
% 	end.

make_reference({Pid, _}) -> 
	make_reference(Pid);
make_reference(Pid) ->
	erlang:monitor(process, Pid).

remove_request(Ref, Requests) ->
	erlang:demonitor(Ref, [flush]),
	maps:remove(Ref, Requests).

request_block1(EndpointPid, Ref, Method, RequestOptions, Content) ->
	request_block1(EndpointPid, Ref, Method, RequestOptions, undefined, Content).

request_block1(EndpointPid, Ref, Method, RequestOptions, Block1, Content) ->
	ecoap_endpoint:send_request(EndpointPid, Ref,
		ecoap_request:set_payload(Content, Block1, ecoap_request:request('CON', Method, RequestOptions))).

request_block2(EndpointPid, Ref, Method, RequestOptions, Block2) ->
	ecoap_endpoint:send_request(EndpointPid, Ref,
        ecoap_request:request('CON', Method, 
        	coap_message:add_option('Block2', Block2, RequestOptions))).

maybe_cancel_ongoing_blocks(EndpointPid, BlockKey, CurrentRef, OngoingBlocks, Requests, RequestMapping) ->
	case maps:find(BlockKey, OngoingBlocks) of
		{ok, CurrentRef} ->
			{Requests, RequestMapping};
		{ok, OngoingBlockRef} ->
			#request{origin_ref=OriginRef} = maps:get(OngoingBlockRef, Requests),
			do_cancel_request(EndpointPid, OngoingBlockRef),
			Requests2 = maps:remove(OngoingBlockRef, Requests),
			RequestMapping2 = maps:remove(OriginRef, RequestMapping),
			{Requests2, RequestMapping2};
		error ->
			{Requests, RequestMapping}
	end.

check_and_cancel_request(Ref, State=#state{endpoint_pid=EndpointPid, requests=Requests, ongoing_blocks=OngoingBlocks, request_mapping=RequestMapping, observe_regs=ObsRegs}) ->
	case {maps:find(Ref, Requests), maps:find(Ref, RequestMapping)} of
		%  ordinary request
		{{ok, #request{origin_ref=Ref, observe_key=ObsKey}}, error} ->
			do_cancel_request(EndpointPid, Ref),
			Requests2 = maps:remove(Ref, Requests),
			ObsRegs2 = maps:remove(ObsKey, ObsRegs),
			State#state{requests=Requests2, observe_regs=ObsRegs2};
		% ongoging blockwise transfer of ordinary request where the origin request has been acked and removed from state
		{error, {ok, BlockRef}} -> 
			#request{origin_ref=Ref, block_key=BlockKey} = maps:get(BlockRef, Requests),
			do_cancel_request(EndpointPid, BlockRef),
			Requests2 = maps:remove(BlockRef, Requests),
			OngoingBlocks2 = maps:remove(BlockKey, OngoingBlocks),
			RequestMapping2 = maps:remove(Ref, RequestMapping),
			State#state{requests=Requests2, ongoing_blocks=OngoingBlocks2, request_mapping=RequestMapping2};
		% ongoging blockwise transfer of observe notification where the origin request & blockwise request stay in state
	    {{ok, #request{origin_ref=Ref, observe_key=ObsKey}}, {ok, BlockRef}} ->
	    	#request{origin_ref=Ref, block_key=BlockKey} = maps:get(BlockRef, Requests),
	    	do_cancel_request(EndpointPid, Ref),
	    	do_cancel_request(EndpointPid, BlockRef),
			Requests2 = maps:remove(Ref, maps:remove(BlockRef, Requests)),
			OngoingBlocks2 = maps:remove(BlockKey, OngoingBlocks),
			RequestMapping2 = maps:remove(Ref, RequestMapping),
			ObsRegs2 = maps:remove(ObsKey, ObsRegs),
			State#state{requests=Requests2, ongoing_blocks=OngoingBlocks2, request_mapping=RequestMapping2, observe_regs=ObsRegs2};
		{_, _} ->
			State
	end.

% check_and_cancel_request(Ref, State=#state{requests=Requests, ongoing_blocks=OngoingBlocks, request_mapping=RequestMapping, observe_regs=ObsRegs}) ->
% 	{Requests2, ObsRegs2} = case maps:find(Ref, Requests) of
% 								{ok, {EndpointPid, #request{origin_ref=Ref, observe_key=ObsKey}}} ->
% 									do_cancel_request(EndpointPid, Ref),
% 									{maps:remove(Ref, Requests), maps:remove(ObsKey, ObsRegs)};
% 								error -> 
% 									{Requests, ObsRegs}
% 							end,
% 	case maps:find(Ref, RequestMapping) of
% 		{ok, BlockRef} ->
% 			{EndpointPid, #request{origin_ref=Ref, block_key=BlockKey}} = maps:get(BlockRef, Requests2),
% 			do_cancel_request(EndpointPid, BlockRef),
% 			OngoingBlocks2 = maps:remove(BlockKey, OngoingBlocks),
% 			RequestMapping2 = maps:remove(Ref, RequestMapping),
% 			Requests3 = maps:remove(BlockRef, Requests2),
% 			State#state{requests=Requests3, ongoing_blocks=OngoingBlocks2, request_mappinp=RequestMapping2, observe_regs=ObsRegs2};
% 		error ->
% 			State#state{requests=Requests2, observe_regs=ObsRegs2};
% 	end.

do_cancel_request(EndpointPid, Ref) ->
	ecoap_endpoint:cancel_request(EndpointPid, Ref).

is_observe(ObsSeq, ObsKey) when is_integer(ObsSeq), is_tuple(ObsKey) -> true;
is_observe(_, _) -> false.

separate(Request=#request{reply_to={Pid, _}}) ->
	Request#request{reply_to=Pid};
separate(Request=#request{}) ->
	Request.

return_response(Message) -> {ok, coap_message:get_code(Message), coap_content:get_content(Message)}.

send_response(#request{reply_to=ReplyTo, origin_ref=Ref, observe_seq=ObsSeq, observe_key=ObsKey}, Response) when is_pid(ReplyTo) ->
	case is_observe(ObsSeq, ObsKey) of
		true -> ReplyTo ! {coap_notify, Ref, self(), ObsSeq, Response}, ok;
		false -> ReplyTo ! {coap_response, Ref, self(), Response}, ok
	end;
send_response(#request{reply_to=ReplyTo}, Response) ->
	gen_server:reply(ReplyTo, Response),
	ok.