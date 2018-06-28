-module(ecoap_client).
-behaviour(gen_server).

%% TODO: add support for configure request type
%% can be done by:
%% 1. change request API from multiple params to using a map of params
%% 2. specify request type in the map
%% 3. return {error, _} when synchronously sending a 'NON' request (which should be send asynchronously)

%% API.
-export([open/0, open/1, close/1]).
-export([ping/2]).
-export([get/2, get/3, get/4, put/3, put/4, put/5, post/3, post/4, post/5, delete/2, delete/3, delete/4]).
-export([get_async/2, get_async/3, put_async/3, put_async/4, post_async/3, post_async/4, delete_async/2, delete_async/3]).
-export([observe/2, observe/3, observe_and_wait_response/2, observe_and_wait_response/3]).
-export([unobserve/2, unobserve/3, unobserve_and_wait_response/2, unobserve_and_wait_response/3]).
-export([cancel_request/2]).
-export([flush/1]).

-ifdef(TEST).
-export([get_reqrefs/1, get_obsregs/1, get_blockregs/1]).
-endif.

-export([start_link/1]).

%% gen_server.
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-record(state, {
	socket = undefined :: {client_socket, pid()} | {server_socket, pid() | atom()},
	requests = #{} :: #{reference() => {pid(), request()}},
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
-type block_key() :: {ecoap_udp_socket:ecoap_endpoint_id(), [binary()]}.

% observe_key() :: {EpID, Path, Accept}
-type observe_key() :: {ecoap_udp_socket:ecoap_endpoint_id(), [binary()], atom() | non_neg_integer()}.

-type response() ::
	{ok, coap_message:success_code() | coap_message:error_code(), coap_content:coap_content()} |
	{error, _}.

-type observe_response() :: 
	{ok, reference(), pid(), non_neg_integer(), response()}.

%% API.
-spec open() -> {ok, pid()}.
open() ->
	start_link({port, 0}).

-spec open({port, inet:port_number()} | {socket, pid() | atom()}) -> {ok, pid()}.
open(Opts) ->
	start_link(Opts).

-spec close(pid()) -> ok.
close(Pid) ->
	gen_server:cast(Pid, shutdown).

-spec ping(pid(), string()) -> ok | {error, _}.
ping(Pid, Uri) ->
	case gen_server:call(Pid, {ping, Uri}, infinity) of
		{error, 'RST'} -> ok;
		Else -> Else
	end.

-spec get(pid(), string()) -> response().
get(Pid, Uri) ->
	request(Pid, 'GET', Uri, <<>>, #{}, infinity).

-spec get(pid(), string(), coap_message:optionset()) -> response().
get(Pid, Uri, Options) ->
	request(Pid, 'GET', Uri, <<>>, Options, infinity).

-spec get(pid(), string(), coap_message:optionset(), non_neg_integer() | infinity) -> response().
get(Pid, Uri, Options, Timeout) ->
	request(Pid, 'GET', Uri, <<>>, Options, Timeout).

-spec get_async(pid(), string()) -> {ok, reference()}.
get_async(Pid, Uri) ->
	request_async(Pid, 'GET', Uri, <<>>, #{}).

-spec get_async(pid(), string(), coap_message:optionset()) -> {ok, reference()}.
get_async(Pid, Uri, Options) ->
	request_async(Pid, 'GET', Uri, <<>>, Options).

-spec put(pid(), string(), binary()) -> response().
put(Pid, Uri, Content) ->
	request(Pid, 'PUT', Uri, Content, #{}, infinity).

-spec put(pid(), string(), binary(), coap_message:optionset()) -> response().
put(Pid, Uri, Content, Options) ->
	request(Pid, 'PUT', Uri, Content, Options, infinity).

-spec put(pid(), string(), binary(), coap_message:optionset(), non_neg_integer() | infinity) -> response().
put(Pid, Uri, Content, Options, Timeout) ->
	request(Pid, 'PUT', Uri, Content, Options, Timeout).

-spec put_async(pid(), string(), binary()) -> {ok, reference()}.
put_async(Pid, Uri, Content) ->
	request_async(Pid, 'PUT', Uri, Content, #{}).

-spec put_async(pid(), string(), binary(), coap_message:optionset()) -> {ok, reference()}.
put_async(Pid, Uri, Content, Options) ->
	request_async(Pid, 'PUT', Uri, Content, Options).

-spec post(pid(), string(), binary()) -> response().
post(Pid, Uri, Content) ->
	request(Pid, 'POST', Uri, Content, #{}, infinity).

-spec post(pid(), string(), binary(), coap_message:optionset()) -> response().
post(Pid, Uri, Content, Options) ->
	request(Pid, 'POST', Uri, Content, Options, infinity).

-spec post(pid(), string(), binary(), coap_message:optionset(), non_neg_integer() | infinity) -> response().
post(Pid, Uri, Content, Options, Timeout) ->
	request(Pid, 'POST', Uri, Content, Options, Timeout).

-spec post_async(pid(), string(), binary()) -> {ok, reference()}.
post_async(Pid, Uri, Content) ->
	request_async(Pid, 'POST', Uri, Content, #{}).

-spec post_async(pid(), string(), binary(), coap_message:optionset()) -> {ok, reference()}.
post_async(Pid, Uri, Content, Options) ->
	request_async(Pid, 'POST', Uri, Content, Options).

-spec delete(pid(), string()) -> response().
delete(Pid, Uri) ->
	request(Pid, 'DELETE', Uri, <<>>, #{}, infinity).

-spec delete(pid(), string(), coap_message:optionset()) -> response().
delete(Pid, Uri, Options) ->
	request(Pid, 'DELETE', Uri, <<>>, Options, infinity).

-spec delete(pid(), string(), coap_message:optionset(), non_neg_integer() | infinity) -> response().
delete(Pid, Uri, Options, Timeout) ->
	request(Pid, 'DELETE', Uri, <<>>, Options, Timeout).

-spec delete_async(pid(), string()) -> {ok, reference()}.
delete_async(Pid, Uri) ->
	request_async(Pid, 'DELETE', Uri, <<>>, #{}).

-spec delete_async(pid(), string(), coap_message:optionset()) -> {ok, reference()}.
delete_async(Pid, Uri, Options) ->
	request_async(Pid, 'DELETE', Uri, <<>>, Options).

-spec request(pid(), coap_message:coap_method(), string(), binary(), coap_message:optionset(), non_neg_integer() | infinity) -> response().
request(Pid, Method, Uri, Content, Options, Timeout) ->
	gen_server:call(Pid, {request, sync, Method, Uri, Content, Options}, Timeout).

-spec request_async(pid(), coap_message:coap_method(), string(), binary(), coap_message:optionset()) -> {ok, reference()}.
request_async(Pid, Method, Uri, Content, Options) ->
	gen_server:call(Pid, {request, async, Method, Uri, Content, Options}).

-spec cancel_request(pid(), reference()) -> ok.
cancel_request(Pid, Ref) ->
	gen_server:call(Pid, {cancel_request, Ref}).

-spec observe(pid(), string()) -> {ok, reference()}.
observe(Pid, Uri) ->
	observe(Pid, Uri, #{}).

-spec observe(pid(), string(), coap_message:optionset()) -> {ok, reference()}.
observe(Pid, Uri, Options) ->
	gen_server:call(Pid, {observe, Uri, Options}).

-spec observe_and_wait_response(pid(), string()) -> observe_response() | response().
observe_and_wait_response(Pid, Uri) ->
	observe_and_wait_response(Pid, Uri, #{}).

-spec observe_and_wait_response(pid(), string(), coap_message:optionset()) -> observe_response() | response().
observe_and_wait_response(Pid, Uri, Options) ->
	{ok, Ref} = observe(Pid, Uri, Options),
	Tag = erlang:monitor(process, Pid),
	receive 
		{coap_notify, Ref, Pid, ObsSeq, Response} ->
			{ok, Ref, Pid, ObsSeq, Response};
		{coap_response, Ref, Pid, Response} ->
			Response;
		{'DOWN', Tag, process, Pid, Reason} ->
			exit(Reason)
	end.

-spec unobserve(pid(), reference()) -> {ok, reference()}.
unobserve(Pid, Ref) ->
	unobserve(Pid, Ref, []).

-spec unobserve(pid(), reference(), [binary()]) -> {ok, reference()}.
unobserve(Pid, Ref, ETag) ->
	gen_server:call(Pid, {unobserve, Ref, ETag}).

-spec unobserve_and_wait_response(pid(), reference()) -> response().
unobserve_and_wait_response(Pid, Ref) ->
	unobserve_and_wait_response(Pid, Ref, []).

-spec unobserve_and_wait_response(pid(), reference(), [binary()]) -> response().
unobserve_and_wait_response(Pid, Ref, ETag) ->
	{ok, Ref2} = unobserve(Pid, Ref, ETag),
	Tag = erlang:monitor(process, Pid),
	receive 
		{coap_response, Ref2, Pid, Response} ->
			Response;
		{'DOWN', Tag, process, Pid, Reason} ->
			exit(Reason)
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

start_link(Opts) ->
	gen_server:start_link(?MODULE, [Opts], []).


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

init([{port, Port}]) ->
	{ok, Socket} = ecoap_udp_socket:start_link([{port, Port}]),
	{ok, #state{socket={client_socket, Socket}}};
init([{socket, Socket}]) ->
	{ok, #state{socket={server_socket, Socket}}}.

handle_call({ping, Uri}, From, State=#state{socket=Socket, requests=Requests}) ->
	{_Scheme, _Host, {PeerIP, PortNo}, _Path, _Query} = ecoap_uri:decode_uri(Uri),
	EpID = {PeerIP, PortNo},
	{ok, EndpointPid} = get_endpoint(Socket, EpID),
	{ok, Ref} = ecoap_endpoint:ping(EndpointPid),
	Request = #request{method=undefined, origin_ref=Ref, reply_to=From},
	{noreply, State#state{requests=maps:put(Ref, {EndpointPid, Request}, Requests)}};

handle_call({request, Sync, Method, Uri, Content, Options}, From, State=#state{socket=Socket, requests=Requests}) ->
	{ok, EpID, _, Options2} = make_request(Uri, Options),
	{ok, EndpointPid} = get_endpoint(Socket, EpID),
	{ok, Ref} = request_block(EndpointPid, Method, Options2, Content),
	case Sync of
		sync ->
			Request = #request{method=Method, options=Options2, content=Content, origin_ref=Ref, reply_to=From},
			{noreply, State#state{requests=maps:put(Ref, {EndpointPid, Request}, Requests)}};
		async ->
			{Pid, _} = From,
			Request = #request{method=Method, options=Options2, content=Content, origin_ref=Ref, reply_to=Pid},
			{reply, {ok, Ref}, State#state{requests=maps:put(Ref, {EndpointPid, Request}, Requests)}}
	end;

% handle_call({observe, Uri, Options}, {Pid, _}, State=#state{socket=Socket, requests=Requests, observe_regs=ObsRegs}) ->
% 	{ok, EpID, Path, Options2} = make_request(Uri, Options),
% 	ObsKey = {EpID, Path, coap_message:get_option('Accept', Options2)},
% 	{Token, Requests2, ObsRegs2} = case maps:find(ObsKey, ObsRegs) of
% 		error -> 
% 			{ecoap_message_token:generate_token(), Requests, ObsRegs};
% 		{ok, {OldRef, OldToken}} ->
% 			{OldToken, maps:remove(OldRef, Requests), maps:remove(ObsKey, ObsRegs)}
% 	end,
% 	{ok, EndpointPid} = get_endpoint(Socket, EpID),
% 	{ok, Ref} = ecoap_endpoint:send(EndpointPid,  
% 					coap_message:set_token(Token,
% 						ecoap_request:request('CON', 'GET', coap_message:add_option('Observe', 0, Options2)))),
% 	Request = #request{method='GET', options=Options2, origin_ref=Ref, reply_to=Pid, observe_key=ObsKey},	
% 	Requests3 = maps:put(Ref, {EndpointPid, Request}, Requests2),
% 	ObsRegs3 = maps:put(ObsKey, {Ref, Token}, ObsRegs2),
% 	{reply, {ok, Ref}, State#state{requests=Requests3, observe_regs=ObsRegs3}};

handle_call({observe, Uri, Options}, {Pid, _}, State=#state{socket=Socket, requests=Requests, observe_regs=ObsRegs}) ->
	{ok, EpID, Path, Options2} = make_request(Uri, Options),
	ObsKey = {EpID, Path, coap_message:get_option('Accept', Options2)},
	{ok, EndpointPid} = get_endpoint(Socket, EpID),
	Ref = case maps:find(ObsKey, ObsRegs) of 
		{ok, OldRef} ->
			{ok, OldRef} = ecoap_endpoint:send_request(EndpointPid, OldRef, 
				ecoap_request:request('CON', 'GET', coap_message:add_option('Observe', 0, Options2))),
			OldRef;
		error ->	
			{ok, NewRef} = ecoap_endpoint:send(EndpointPid, 
				ecoap_request:request('CON', 'GET', coap_message:add_option('Observe', 0, Options2))),
			NewRef
	end,
	Request = #request{method='GET', options=Options2, origin_ref=Ref, reply_to=Pid, observe_key=ObsKey},
	Requests2 = maps:put(Ref, {EndpointPid, Request}, Requests),
	ObsRegs2 = maps:put(ObsKey, Ref, ObsRegs),
	{reply, {ok, Ref}, State#state{requests=Requests2, observe_regs=ObsRegs2}};

handle_call({unobserve, Ref, ETag}, {Pid, _}, 
	State=#state{requests=Requests, request_mapping=RequestMapping, observe_regs=ObsRegs}) ->
	case maps:find(Ref, Requests) of
		error ->
			{reply, {error, no_observe}, State};
		{ok, {_, #request{observe_key=undefined}}} ->
			{reply, {error, no_observe}, State};
		{ok, {EndpointPid, #request{options=Options, observe_key=ObsKey} = Request}} ->
			Ref = maps:get(ObsKey, ObsRegs),
			Options2 = coap_message:add_option('ETag', ETag, Options),
			{ok, Ref} = ecoap_endpoint:send_request(EndpointPid, Ref,
							ecoap_request:request('CON', 'GET', coap_message:add_option('Observe', 1, Options2))),
			Request2 = Request#request{options=Options2, origin_ref=Ref, reply_to=Pid}, 
			State2 = check_and_cancel_request(maps:get(Ref, RequestMapping, undefined), State),
			{reply, {ok, Ref},  State2#state{requests=maps:put(Ref, {EndpointPid, Request2}, Requests)}}
	end;

handle_call({cancel_request, Ref}, _From, State) ->
	{reply, ok, check_and_cancel_request(Ref, State)};

handle_call(get_reqrefs, _From, State=#state{requests=Requests}) ->
	{reply, Requests, State};
handle_call(get_blockregs, _From, State=#state{ongoing_blocks=OngoingBlocks}) ->
	{reply, OngoingBlocks, State};
handle_call(get_obsregs, _From, State=#state{observe_regs=ObsRegs}) ->
	{reply, ObsRegs, State};

handle_call(_Request, _From, State) ->
	{reply, ignored, State}.

handle_cast(shutdown, State) ->
	{stop, normal, State};
handle_cast(_Msg, State) ->
	{noreply, State}.

handle_info({coap_response, EpID, EndpointPid, Ref, Message}, State=#state{requests=Requests}) ->
	case maps:find(Ref, Requests) of
		error -> 
			{noreply, State};
		{ok, {EndpointPid, Request}} ->
			case coap_message:get_type(Message) of
				'CON' -> {ok, _} = ecoap_endpoint:send(EndpointPid, ecoap_request:ack(Message)), ok;
				_ -> ok
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

handle_info({coap_error, _EpID, EndpointPid, Ref, Error}, State=#state{requests=Requests}) ->
	case maps:find(Ref, Requests) of
		error -> 
			{noreply, State};
		{ok, {EndpointPid, Request}} ->
			handle_error(Ref, Request, {coap_error, Error}, State)
	end;

handle_info({coap_ack, _EpID, EndpointPid, Ref}, State=#state{requests=Requests}) ->
	case maps:find(Ref, Requests) of
		{ok, {EndpointPid, #request{} = Request}} ->
			send_response(Request, {separate, Ref}),
			Requests2 = maps:put(Ref, {EndpointPid, separate(Request)}, Requests),
			{noreply, State#state{requests=Requests2}};
		error -> 
			{noreply, State}
	end;

handle_info(_Info, State) ->
	{noreply, State}.

terminate(_Reason, #state{socket={client_socket, Socket}}) ->
	ok = ecoap_udp_socket:close(Socket),
	ok;
terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%% Internal
handle_upload(EpID, EndpointPid, Ref, Request, Message, State=#state{requests=Requests, ongoing_blocks=OngoingBlocks, request_mapping=RequestMapping}) ->
	#request{method=Method, options=RequestOptions, content=Content, origin_ref=OriginRef} = Request,
	{Num, true, Size} = coap_message:get_option('Block1', Message),
	{ok, Ref2} = request_block(EndpointPid, Method, RequestOptions, {Num+1, false, Size}, Content),
	% store ongoing block1 transfer
	BlockKey = {EpID, coap_message:get_option('Uri-Path', RequestOptions)},
	{Requests2, RequestMapping2} = maybe_cancel_ongoing_blocks(EndpointPid, BlockKey, Ref, OngoingBlocks, Requests, RequestMapping),
	OngoingBlocks2 = maps:put(BlockKey, Ref2, OngoingBlocks),
	% update request mapping
	RequestMapping3 = maps:put(OriginRef, Ref2, RequestMapping2),
	Requests3 = maps:put(Ref2, {EndpointPid, Request#request{block_key=BlockKey}}, maps:remove(Ref, Requests2)),
	{noreply, State#state{requests=Requests3, ongoing_blocks=OngoingBlocks2, request_mapping=RequestMapping3}}.

handle_download(EpID, EndpointPid, Ref, Request, Message, 
	State=#state{requests=Requests, ongoing_blocks=OngoingBlocks, request_mapping=RequestMapping, observe_regs=ObsRegs}) ->
	#request{method=Method, options=RequestOptions, origin_ref=OriginRef, 
		fragment=Fragment, observe_seq=Seq, observe_key=ObsKey} = Request,
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
            {ok, Ref2} = ecoap_endpoint:send(EndpointPid,
                ecoap_request:request('CON', Method, 
                	coap_message:add_option('Block2', {Num+1, false, Size}, RequestOptions))),
            % store ongoing block2 transfer
			OngoingBlocks2 = maps:put(BlockKey, Ref2, OngoingBlocks),
            Request2 = Request#request{block_key=BlockKey, observe_seq=ObsSeq, fragment= <<Fragment/binary, Data/binary>>},
            {Requests3, ObsRegs2} = case ObsSeq of
            	undefined -> 
            		% not an observe notification, update requests record and clean observe reg
            		{maps:put(Ref2, {EndpointPid, Request2}, maps:remove(Ref, Requests2)), maps:remove(ObsKey, ObsRegs)};
            	_ ->               
            		case Ref of
            			OriginRef ->
            				% first block of an observe notification, update requests record but do not remove origin request
            				{maps:put(Ref2, {EndpointPid, Request2}, Requests2), ObsRegs};
            			_ ->
            				% following block of an observe notification, update requests record
            				{maps:put(Ref2, {EndpointPid, Request2}, maps:remove(Ref, Requests2)), ObsRegs}
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
			{Requests3, ObsRegs2} = case ObsSeq of
				undefined -> 
					% not an observe notification, clean all state including observe registry
					{maps:remove(Ref, Requests2), maps:remove(ObsKey, ObsRegs)};
				_ ->
					case Ref of 
						OriginRef -> 
							% an observe notification not segmented, keep origin request 
							{Requests2, ObsRegs};
						_ ->
							% all blocks of an observe notification received, clean last block reference
							{maps:remove(Ref, Requests2), ObsRegs}
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

make_request(Uri, Options) ->
	{_Scheme, Host, {PeerIP, PortNo}, Path, Query} = ecoap_uri:decode_uri(Uri),
	EpID = {PeerIP, PortNo},
 	Options2 = coap_message:add_option('Uri-Path', Path, 
					coap_message:add_option('Uri-Query', Query,
						coap_message:add_option('Uri-Host', Host, 
							coap_message:add_option('Uri-Port', PortNo, Options)))),
 	{ok, EpID, Path, Options2}.

get_endpoint(Socket={_, SocketPid}, EpID) ->
	{ok, EndpointPid} = ecoap_udp_socket:get_endpoint(SocketPid, EpID),
	try link(EndpointPid) of
		true -> {ok, EndpointPid}
	catch error:noproc -> 
		get_endpoint(Socket, EpID)
	end.

request_block(EndpointPid, Method, RequestOptions, Content) ->
    request_block(EndpointPid, Method, RequestOptions, undefined, Content).

request_block(EndpointPid, Method, RequestOptions, Block1, Content) ->
	ecoap_endpoint:send(EndpointPid, 
		ecoap_request:set_payload(Content, Block1, ecoap_request:request('CON', Method, RequestOptions))).

maybe_cancel_ongoing_blocks(EndpointPid, BlockKey, CurrentRef, OngoingBlocks, Requests, RequestMapping) ->
	case maps:find(BlockKey, OngoingBlocks) of
		{ok, CurrentRef} ->
			{Requests, RequestMapping};
		{ok, OngoingBlockRef} ->
			{EndpointPid, #request{origin_ref=OriginRef}} = maps:get(OngoingBlockRef, Requests),
			do_cancel_request(EndpointPid, OngoingBlockRef),
			Requests2 = maps:remove(OngoingBlockRef, Requests),
			RequestMapping2 = maps:remove(OriginRef, RequestMapping),
			{Requests2, RequestMapping2};
		error ->
			{Requests, RequestMapping}
	end.

check_and_cancel_request(Ref, State=#state{requests=Requests, ongoing_blocks=OngoingBlocks, request_mapping=RequestMapping, observe_regs=ObsRegs}) ->
	case {maps:find(Ref, Requests), maps:find(Ref, RequestMapping)} of
		%  ordinary request
		{{ok, {EndpointPid, #request{origin_ref=Ref, observe_key=ObsKey}}}, error} ->
			do_cancel_request(EndpointPid, Ref),
			Requests2 = maps:remove(Ref, Requests),
			ObsRegs2 = maps:remove(ObsKey, ObsRegs),
			State#state{requests=Requests2, observe_regs=ObsRegs2};
		% ongoging blockwise transfer of ordinary request where the origin request has been acked and removed from state
		{error, {ok, BlockRef}} -> 
			{EndpointPid, #request{origin_ref=Ref, block_key=BlockKey}} = maps:get(BlockRef, Requests),
			do_cancel_request(EndpointPid, BlockRef),
			Requests2 = maps:remove(BlockRef, Requests),
			OngoingBlocks2 = maps:remove(BlockKey, OngoingBlocks),
			RequestMapping2 = maps:remove(Ref, RequestMapping),
			State#state{requests=Requests2, ongoing_blocks=OngoingBlocks2, request_mapping=RequestMapping2};
		% ongoging blockwise transfer of observe notification where the origin request & blockwise request stay in state
	    {{ok, {EndpointPid, #request{origin_ref=Ref, observe_key=ObsKey}}}, {ok, BlockRef}} ->
	    	{EndpointPid, #request{origin_ref=Ref, block_key=BlockKey}} = maps:get(BlockRef, Requests),
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

separate(Request=#request{reply_to={Pid, _}}) ->
	Request#request{reply_to=Pid};
separate(Request=#request{}) ->
	Request.

return_response(Message) -> {ok, coap_message:get_code(Message), coap_content:get_content(Message)}.

send_response(#request{reply_to=ReplyTo, origin_ref=Ref, observe_seq=undefined}, Response) when is_pid(ReplyTo) ->
	ReplyTo ! {coap_response, Ref, self(), Response},
	ok;
send_response(#request{reply_to=ReplyTo, origin_ref=Ref, observe_seq=ObsSeq}, Response) when is_pid(ReplyTo) ->
	ReplyTo ! {coap_notify, Ref, self(), ObsSeq, Response}, 
	ok;
send_response(#request{reply_to=ReplyTo}, Response) ->
	gen_server:reply(ReplyTo, Response),
	ok.