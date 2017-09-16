-module(ecoap_client).
-behaviour(gen_server).

%% API.
-export([start_link/0]).
-export([close/1]).
%% ping the server
-export([ping/2]).
%% sync request
-export([request/3, request/4, request/5, request/6]).
%% async request
-export([async_request/3, async_request/4, async_request/5]).
%% observe
-export([observe/2, observe/3, unobserve/2, unobserve/3]).
-export([async_observe/2, async_observe/3, async_unobserve/2, async_unobserve/3]).
%% cancel and flush
-export([cancel_async_request/2, flush/1]).

-ifdef(TEST).
%% utilities
-export([get_reqrefs/1, get_obsregs/1, get_blockregs/1]).
-endif.

%% gen_server.
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-record(state, {
	sock_pid = undefined :: pid(),
	req_refs = #{} :: #{reference() => req()},
	% block_regs maps target resource to ongoing blockwise transfer against that resource
	block_regs = #{} :: #{block_key() => reference()},
	% obs_regs maps target resource to token used in that observe relation
	obs_regs = #{} :: #{observe_key() => binary()},
	subscribers = [] :: [{{pid(), observe_key()}, reference(), reference()}]
}).

-record(req, {
	type = undefined :: 'CON' | 'NON',
	method = undefined :: undefined | coap_message:coap_method(),
	options = #{} :: coap_message:optionset(),
	token = <<>> :: binary(),
	content = undefined :: undefined | binary(),
	fragment = <<>> :: binary(),
	% req_ref is the original request reference that user started, 
	% which is inheritated among successive request(s), if any
	req_ref = undefined :: undefined | reference(),
	reply_pid = undefined :: pid(),
	% block_obseq is the observe sequence num of a blockwise notification 
	% which is inheritated among successive blockwise transfer request(s)
	block_obseq = undefined :: undefined | non_neg_integer(),
	obs_key = undefined :: undefined | observe_key(),
	block_key = undefined :: undefined | block_key(),
	ep_id = undefined :: ecoap_udp_socket:ecoap_endpoint_id(),
	ep = undefined :: pid()
}).

-include("ecoap.hrl").

-type req() :: #req{}.
-type response() :: 
	{ok, coap_message:success_code(), binary(), coap_message:optionset()} | 
	{error, timeout} |
	{error, coap_message:error_code()} | 
	{error, coap_message:error_code(), binary(), coap_message:optionset()} | 
	{separate, reference()}.
-type observe_response() :: 
	{ok, reference(), pid(), non_neg_integer(), coap_message:success_code(), binary(), coap_message:optionset()} | response().

-type observe_key() :: {ecoap_udp_socket:ecoap_endpoint_id(), [binary()], atom() | non_neg_integer()}.
-type block_key() :: {ecoap_udp_socket:ecoap_endpoint_id(), [binary()]}.

-opaque state() :: #state{}.
-export_type([state/0]).

%% API.

-spec start_link() -> {ok, pid()}.
start_link() ->
	gen_server:start_link(?MODULE, [], []).

-spec close(pid()) -> ok.
close(Pid) ->
	gen_server:stop(Pid).

-spec ping(pid(), string()) -> ok | error.
ping(Pid, Uri) ->
	{_Scheme, _Host, EpID, _Path, _Query} = ecoap_utils:decode_uri(Uri),
	case send_request(Pid, EpID, ping, infinity) of
		{error, 'RST'} -> ok;
		_Else -> error
	end.

% Send a request synchronously

% Returns response of the sent request in the following format:
% Sucess response: {ok, Code, Content, ExtraOptions} where ExtraOptions is a list of options that are not covered by the ones in Content
% Error response: {error, Code}; {error, Code, Content}
% When server decides to respond with a separate response, returns {separate, Reference} where Reference can be used to match response later or cancel the request
% The separate response will be sent as message in format of {coap_response, Reference, Pid, Response} where Pid is the process ID of ecoap_client, Response is any of the Success/Error Response
% When sending a confirmable request and server is not responsive, returns {error, timeout}

% Note the synchronous request function always behave in a synchronous way no matter what the message type is
% Therefore one should always use the asynchronous request function to send a non-confirmable request 
% if there is a risk that the response gets lost and we wait forever

-spec request(pid(), coap_message:coap_method(), string()) -> response().
request(Pid, Method, Uri) ->
	request(Pid, Method, Uri, <<>>, #{}, infinity).

-spec request(pid(), coap_message:coap_method(), string(), binary()) -> response().
request(Pid, Method, Uri, Content) -> 
	request(Pid, Method, Uri, Content, #{}, infinity).

-spec request(pid(), coap_message:coap_method(), string(), binary(), coap_message:optionset()) -> response().
request(Pid, Method, Uri, Content, Options) ->
	request(Pid, Method, Uri, Content, Options, infinity).

-spec request(pid(), coap_message:coap_method(), string(), binary(), coap_message:optionset(), infinity | non_neg_integer()) -> response().
request(Pid, Method, Uri, Content, Options, Timeout) ->
	{EpID, Req} = assemble_request(Method, Uri, Options, Content),
	send_request(Pid, EpID, Req, Timeout).

% Send a request asynchronously

% Returns {ok, Reference} where Reference can be used to match response later or cancel the request
% The asynchronous response will be sent as message in format of {coap_response, Reference, Pid, Response} 
% where Pid is the process ID of ecoap_client, Response is any of the Success/Error Response (including {error, timeout}), same as in synchronous request function

% Specially, when combined with separate response, two asychronous responses will be sent as messages 
% The first one is in format of {coap_response, Reference, Pid, {separate, Reference}} 
% and the second one, a.k.a. the real response is in normal form: {coap_response, Reference, Pid, Response}

-spec async_request(pid(), coap_message:coap_method(), string()) -> {ok, reference()}.
async_request(Pid, Method, Uri) ->
	async_request(Pid, Method, Uri, <<>>, #{}).

-spec async_request(pid(), coap_message:coap_method(), string(), binary()) -> {ok, reference()}.
async_request(Pid, Method, Uri, Content) -> 
	async_request(Pid, Method, Uri, Content, #{}).

-spec async_request(pid(), coap_message:coap_method(), string(), binary(), coap_message:optionset()) -> {ok, reference()}.
async_request(Pid, Method, Uri, Content, Options) ->
	{EpID, Req} = assemble_request(Method, Uri, Options, Content),
	send_request(Pid, EpID, Req).

% send_request_sync(Pid, EpID, Req, ReplyPid) ->
% 	% set timeout to infinity because ecoap_endpoint will always return a response, 
% 	% i.e. an ordinary response or {error, timeout} when server does not respond to a confirmable request
% 	gen_server:call(Pid, {send_request, sync, EpID, Req, ReplyPid}, infinity).

send_request(Pid, EpID, Req) -> 
	gen_server:call(Pid, {send_request, EpID, Req, self()}).

send_request(Pid, EpID, Req, Timeout) ->
	{ok, ReqRef} = gen_server:call(Pid, {send_request, EpID, Req, self()}),
	wait_for_response(Pid, ReqRef, Timeout).
		
% send_request(Pid, EpID, Req, Timeout) ->
% 	Tag = make_ref(),
% 	Caller = self(),
%     {Receiver, RecMref} = 
%     	erlang:spawn_monitor(
%     		% Middleman process. Should be unsensitive to regular
% 		  	% exit signals. 
% 		  	fun() ->
% 				process_flag(trap_exit, true),
% 				{ok, ReqRef} = gen_server:call(Pid, {send_request, EpID, Req, self()}),
% 				ToMref = erlang:monitor(process, Pid),
% 				CallerMref = erlang:monitor(process, Caller),
% 				receive 
% 					{coap_response, ReqRef, Pid, Result} ->
% 						exit({self(), Tag, Result});
% 					{'DOWN', ToMref, _, _, Reason} ->
% 						% target process died with Reason and so do we
% 						exit(Reason);
% 					{'DOWN', CallerMref, _, _, _} ->
% 						% Caller exit before request complete 
% 						% we clean state and sliently give up
% 			  			cancel_async_request(Pid, ReqRef),
% 						ok
% 				after Timeout ->
% 					cancel_async_request(Pid, ReqRef),
% 					exit(timeout)
% 				end
% 			end),
%    	receive
% 		{'DOWN', RecMref, _, _, {Receiver, Tag, Result}} ->
% 	    	Result;
% 		{'DOWN', RecMref, _, _, Reason} ->
% 	    	check_exit(Reason)
%     end.
	
% check_exit(timeout) -> {error, timeout};
% check_exit(Reason) -> exit(Reason).

% Start an observe relation to a specific resource

% If the observe relation is established sucessfully, this function returns the first notification as {ok, ReqRef, Pid, N, Code, Content}
% where ReqRef is the reference used to identify following notifications, Pid is the ecoap_client pid, N is the initial observe sequence number.
% If the resource is not observable, the function just returns the response as if it was from a plain GET request.
% If the request time out, this function returns {error, timeout}.

% Following notifications will be sent to the caller process as messages in form of {coap_notify, ReqRef, Pid, N, Res}
% where ReqRef is the reference, Pid is the ecoap_client pid, N is the observe sequence number and Res is the response content.
% If some error happened in server side, e.g. a reset/error code is received during observing
% the response is sent to the caller process as message in form of {coap_notify, ReqRef, Pid, undefined, Res} where Res is {error, _}.

% If the ecoap_client process crashed during the calll, the call fails with reason noproc.

-spec observe(pid(), string()) -> observe_response().
observe(Pid, Uri) ->
	observe(Pid, Uri, #{}).

-spec observe(pid(), string(), coap_message:optionset()) -> observe_response().
observe(Pid, Uri, Options) ->
	{EpID, Key, Req} = assemble_observe_request(Uri, Options),
	% start monitor after we got ReqRef in case the gen_server call crash and we are left with the unused monitor
	{ok, ReqRef} = gen_server:call(Pid, {start_observe, EpID, Key, Req, self()}),
	wait_for_response(Pid, ReqRef, infinity).

-spec async_observe(pid(), string()) -> {ok, reference()}.
async_observe(Pid, Uri) ->
	async_observe(Pid, Uri, #{}).

-spec async_observe(pid(), string(), coap_message:optionset()) -> {ok, reference()}.
async_observe(Pid, Uri, Options) ->
	{EpID, Key, Req} = assemble_observe_request(Uri, Options),
	gen_server:call(Pid, {start_observe, EpID, Key, Req, self()}).

% Cancel an observe relation to a specific resource

% If unobserve resource succeed, the function returns the response as if it was from a plain GET request;
% If the request time out, this function returns {error, timeout}.
% If no matching observe relation exists, the function returns {error, no_observe}.
% note observe relation is matched against URI and accept content-format;
% If the ecoap_client process crashed during the call, the call fails with reason noproc.

-spec unobserve(pid(), reference()) -> response() | {error, no_observe}.
unobserve(Pid, Ref) ->
	unobserve(Pid, Ref, undefined).

-spec unobserve(pid(), reference(), binary() | undefined) -> response() | {error, no_observe}.
unobserve(Pid, Ref, ETag) ->
	case gen_server:call(Pid, {cancel_observe, Ref, ETag}) of
		{ok, ReqRef} -> wait_for_response(Pid, ReqRef, infinity);
		Else -> Else
	end.

-spec async_unobserve(pid(), reference()) -> {ok, reference()} | {error, no_observe}.
async_unobserve(Pid, Ref) ->
	async_unobserve(Pid, Ref, undefined).

-spec async_unobserve(pid(), reference(), binary() | undefined) -> {ok, reference()} | {error, no_observe}.
async_unobserve(Pid, Ref, ETag) ->
	gen_server:call(Pid, {cancel_observe, Ref, ETag}).

wait_for_response(Pid, ReqRef, Timeout) ->
	MonRef = erlang:monitor(process, Pid),
	receive
		{coap_response, ReqRef, Pid, Result} ->
			erlang:demonitor(MonRef, [flush]),
			Result;
		% Server does not support observing the resource or an error happened
		{coap_notify, ReqRef, Pid, undefined, Res} ->
			erlang:demonitor(MonRef, [flush]),
			Res;
		{coap_notify, ReqRef, Pid, N, {ok, Code, Payload, Options}} -> 
			erlang:demonitor(MonRef, [flush]),
			{ok, ReqRef, Pid, N, Code, Payload, Options};
		% if target process is on a remote node
		{'DOWN', MonRef, _, _, noconnection} ->
			exit({nodedown, node(Pid)});
		% target process exit with Reason and so do we
		{'DOWN', MonRef, process, Pid, Reason} -> 
			exit(Reason)
	after Timeout ->
		erlang:demonitor(MonRef, [flush]),
		cancel_async_request(Pid, ReqRef),
		exit(timeout)
	end.

% Note this function can cancel an async request that has not been responded yet, e.g. a long term seperate response
% It can also be used to cancel an observe relation reactively, 
% i.e. cancel it by removing token info and let next notification be rejected
% Blockwise transfer is cancelled by removing the origin request token and its record completely
% so that if the cancellation occurs before a blockwise transfer finish, next block response will be discarded and no new request will be sent

-spec cancel_async_request(pid(), reference()) -> ok.
cancel_async_request(Pid, Ref) ->
	gen_server:cast(Pid, {cancel_async_request, Ref}).

% flush unwanted async response/notification, i.e. after cancelling an async request
flush(ReqRef) ->
	receive
		{coap_response, ReqRef, _, _} ->
			flush(ReqRef);
		{coap_notify, ReqRef, _, _, _} ->
			flush(ReqRef)
	after 0 ->
		ok
	end.	

assemble_request(Method, Uri, Options, Payload) ->
	{_Scheme, Host, {PeerIP, PortNo}, Path, Query} = ecoap_utils:decode_uri(Uri),
	Options2 = coap_message:add_option('Uri-Path', Path, 
					coap_message:add_option('Uri-Query', Query,
						coap_message:add_option('Uri-Host', Host, 
							coap_message:add_option('Uri-Port', PortNo, Options)))),
	EpID = {PeerIP, PortNo},
	Req = {'CON', Method, Options2, Payload},
	{EpID, Req}.

assemble_observe_request(Uri, Options) ->
	{_Scheme, Host, {PeerIP, PortNo}, Path, Query} = ecoap_utils:decode_uri(Uri),
	Accpet = coap_message:get_option('Accpet', Options),
	Options2 = coap_message:add_option('Observe', 0,
					coap_message:add_option('Uri-Path', Path, 
						coap_message:add_option('Uri-Query', Query,
							coap_message:add_option('Uri-Host', Host, 
								coap_message:add_option('Uri-Port', PortNo, Options))))),
	EpID = {PeerIP, PortNo},
	Key = {EpID, Path, Accpet},
	Req = {'CON', 'GET', Options2, <<>>},
	{EpID, Key, Req}.

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

init([]) ->
	{ok, SockPid} = ecoap_udp_socket:start_link(),
	{ok, #state{sock_pid=SockPid}}.

handle_call({send_request, EpID, ping, ReplyPid}, _From, State=#state{sock_pid=SockPid, req_refs=ReqRefs}) ->
	{ok, EndpointPid} = get_endpoint(SockPid, EpID),
	{ok, Ref} = ecoap_endpoint:ping(EndpointPid),
	Req = #req{type='CON', method=undefined, req_ref=Ref, reply_pid=ReplyPid, ep=EndpointPid, ep_id=EpID},
	{reply, {ok, Ref}, State#state{req_refs=store_ref(Ref, Req, ReqRefs)}};

handle_call({send_request, EpID, {Type, Method, Options, Content}, ReplyPid}, _From, State=#state{sock_pid=SockPid, req_refs=ReqRefs, block_regs=BlockRegs}) ->
	{ok, EndpointPid} = get_endpoint(SockPid, EpID),
	{ok, Ref, BlockKey} = request_block(EpID, EndpointPid, Type, Method, Options, Content),
	{ReqRefs2, BlockRegs2} = update_block_transfer_status(EndpointPid, BlockKey, undefined, Ref, ReqRefs, BlockRegs),
	Req = #req{
				type=Type, 
				method=Method, 
				options=Options, 
				content=Content, 
				req_ref=Ref, 
				reply_pid=ReplyPid, 
				block_key=BlockKey, 
				ep=EndpointPid, 
				ep_id=EpID
			},
	{reply, {ok, Ref}, State#state{req_refs=store_ref(Ref, Req, ReqRefs2), block_regs=BlockRegs2}};

handle_call({start_observe, EpID, Key, {Type, Method, Options, _Content}, ReplyPid}, _From, State=#state{sock_pid=SockPid, req_refs=ReqRefs, obs_regs=ObsRegs, subscribers=Subscribers}) ->
	{Token, ObsRegs2} = case find_ref(Key, ObsRegs) of
		undefined -> 
			NewToken = ecoap_endpoint:generate_token(), 
			{NewToken, store_ref(Key, NewToken, ObsRegs)};
		OldToken -> 
			{OldToken, ObsRegs}
	end,
	{ok, EndpointPid} = get_endpoint(SockPid, EpID),
	{ok, Ref} = ecoap_endpoint:send(EndpointPid,  
					coap_message:set_token(Token,
						ecoap_request:request(Type, Method, Options))),	
	Options2 = coap_message:remove_option('Observe', Options),
	Req = #req{
				type=Type,
				method=Method, 
				options=Options2, 
				token=Token, 
				req_ref=Ref, 
				reply_pid=ReplyPid, 
				obs_key=Key, 
				ep=EndpointPid, 
				ep_id=EpID
			},
	{Subscribers2, ReqRefs2} = case lists:keyfind({ReplyPid, Key}, 1, Subscribers) of
		{{ReplyPid, Key}, _MonRef, ReqRef} ->
			Subs = lists:keyreplace({ReplyPid, Key}, 1,  Subscribers, {{ReplyPid, Key}, _MonRef, Ref}),
			{Subs, store_ref(Ref, Req, delete_ref(ReqRef, ReqRefs))};
		false ->
			{[{{ReplyPid, Key}, erlang:monitor(process, ReplyPid), Ref} | Subscribers], store_ref(Ref, Req, ReqRefs)}
	end,
	{reply, {ok, Ref}, State#state{obs_regs=ObsRegs2, req_refs=ReqRefs2, subscribers=Subscribers2}};

handle_call({cancel_observe, Ref, ETag}, _From, State=#state{req_refs=ReqRefs, obs_regs=ObsRegs, subscribers=Subscribers}) ->
	case find_ref(Ref, ReqRefs) of
		undefined -> 
			{reply, {error, no_observe}, State};
		#req{obs_key=undefined} -> 
			{reply, {error, no_observe}, State};
		#req{type=Type, method=Method, options=Options, token=Token, obs_key=Key, ep=EndpointPid, ep_id=EpID, reply_pid=ReplyPid} ->
			Options1 = coap_message:add_option('ETag', ETag, Options),
			Options2 = coap_message:add_option('Observe', 1, Options1),
			{ok, Ref2} = ecoap_endpoint:send(EndpointPid,  
							coap_message:set_token(Token, 
								ecoap_request:request(Type, Method, Options2))),
			Req = #req{type=Type, method=Method, options=Options1, token=Token, req_ref=Ref2, reply_pid=ReplyPid, ep=EndpointPid, ep_id=EpID},
			{{ReplyPid, Key}, MonRef, Ref} = Sub = lists:keyfind({ReplyPid, Key}, 1, Subscribers),
			erlang:demonitor(MonRef, [flush]),
			{reply, {ok, Ref2}, State#state{req_refs=store_ref(Ref2, Req, delete_ref(Ref, ReqRefs)),
										    obs_regs=delete_ref(Key, ObsRegs),
											subscribers=lists:delete(Sub, Subscribers)}}
	end;

handle_call(get_reqrefs, _From, State=#state{req_refs=ReqRefs}) ->
	{reply, ReqRefs, State};
handle_call(get_obsregs, _From, State=#state{obs_regs=ObsRegs}) ->
	{reply, ObsRegs, State};
handle_call(get_blockregs, _From, State=#state{block_regs=BlockRegs}) ->
	{reply, BlockRegs, State};

handle_call(_Request, _From, State) ->
	{noreply, State}.

handle_cast({cancel_async_request, Ref}, State) ->
	{noreply, cancel_request(Ref, State)};
handle_cast(_Msg, State) ->
	{noreply, State}.

% response arrived as a separate CON msg
handle_info({coap_response, _EpID, EndpointPid, Ref, Message=#{type:='CON'}}, State) ->
	{ok, _} = ecoap_endpoint:send(EndpointPid, ecoap_request:ack(Message)),
	handle_response(Ref, EndpointPid, Message, State);

handle_info({coap_response, _EpID, EndpointPid, Ref, Message}, State) ->
	handle_response(Ref, EndpointPid, Message, State);

% handle separate response acknowledgement
handle_info({coap_ack, _EpID, _EndpointPid, Ref}, State) ->
	handle_ack(Ref, State);

% handle RST and timeout
handle_info({coap_error, _EpID, _EndpointPid, Ref, Error}, State) ->
	handle_error(Ref, Error, State);

handle_info({remove_observe_ref, Key, ReplyPid}, State=#state{obs_regs=ObsRegs, subscribers=Subscribers}) ->
	{{ReplyPid, Key}, _MonRef, _ReqRef} = Sub = lists:keyfind({ReplyPid, Key}, 1, Subscribers),
	{noreply, State#state{obs_regs=delete_ref(Key, ObsRegs), 
						  subscribers=lists:delete(Sub, Subscribers)}};

handle_info({'DOWN', MonRef, process, ReplyPid, _Reason}, State=#state{subscribers=Subscribers}) ->
	case lists:keyfind(MonRef, 2, Subscribers) of
		{{ReplyPid, _Key}, MonRef, ReqRef} = Sub ->
			State2 = cancel_request(ReqRef, State),
			{noreply, State2#state{subscribers=lists:delete(Sub, Subscribers)}};
		false ->
			{noreply, State}
	end;

handle_info(_Info, State) ->
	{noreply, State}.

terminate(_Reason, #state{sock_pid=SockPid}) ->
	ok = ecoap_udp_socket:close(SockPid),
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%% Internal

request_block(EpID, EndpointPid, Type, Method, ROpt, Content) ->
    request_block(EpID, EndpointPid, Type, Method, ROpt, undefined, Content).

request_block(EpID, EndpointPid, Type, Method, ROpt, Block1, Content) ->
	RequestMessage = ecoap_request:set_payload(Content, Block1, ecoap_request:request(Type, Method, ROpt)),
	{ok, Ref} = ecoap_endpoint:send(EndpointPid, RequestMessage),
	HasBlock = coap_message:has_option('Block1', RequestMessage) orelse coap_message:has_option('Block2', RequestMessage),
	BlockKey = case HasBlock of 
		true -> {EpID, coap_message:get_option('Uri-Path', ROpt)};
		false -> undefined
	end,
	{ok, Ref, BlockKey}.

update_block_transfer_status(_, undefined, _, _, ReqRefs, BlockRegs) -> {ReqRefs, BlockRegs};
update_block_transfer_status(EndpointPid, BlockKey, CurrentRef, NewRef, ReqRefs, BlockRegs) ->
	case find_ref(BlockKey, BlockRegs) of
		undefined -> 
			{ReqRefs, store_ref(BlockKey, NewRef, BlockRegs)};
		CurrentRef -> 
			{ReqRefs, store_ref(BlockKey, NewRef, BlockRegs)};
		BlockRef ->
			#req{req_ref=ReqRef, obs_key=Key} = find_ref(BlockRef, ReqRefs),
			% if the original request starts an observe relation we dont cancel it
			case Key of undefined -> do_cancel_request(EndpointPid, ReqRef); _ -> ok end,
			do_cancel_request(EndpointPid, BlockRef),
			{delete_ref(ReqRef, delete_ref(BlockRef, ReqRefs)), store_ref(BlockKey, NewRef, BlockRegs)}
	end.

get_endpoint(SockPid, EpID) ->
	{ok, EndpointPid} = ecoap_udp_socket:get_endpoint(SockPid, EpID),
	case ecoap_endpoint:check_alive(EndpointPid) of
		true -> {ok, EndpointPid};
		false -> get_endpoint(SockPid, EpID)
	end.

% function to cancel request(s) using user side request reference
% cancel async request in following cases:
% 1. ordinary req, including non req, separate res, observe con/non req
% 2. blockwise transfer for both con and non
% 3. blockwise transfer for both con and non, during an observe
cancel_request(ReqRef, State=#state{req_refs=ReqRefs, obs_regs=ObsRegs, block_regs=BlockRegs, subscribers=Subscribers}) ->
	case find_ref(ReqRef, ReqRefs) of
		undefined -> State;
		#req{ep=EndpointPid, obs_key=Key, reply_pid=ReplyPid, block_key=BlockKey} ->
			do_cancel_request(EndpointPid, ReqRef),
			ReqRefs2 = case BlockKey of 
				undefined -> 
					delete_ref(ReqRef, ReqRefs);
				_ -> 
					BlockRef = find_ref(BlockKey, BlockRegs),
					do_cancel_request(EndpointPid, BlockRef),
					delete_ref(ReqRef, delete_ref(BlockRef, ReqRefs))
			end,
			State#state{req_refs=ReqRefs2,
						block_regs=delete_ref(BlockKey, BlockRegs), 
						obs_regs=delete_ref(Key, ObsRegs), 
						subscribers=lists:keydelete({ReplyPid, Key}, 1, Subscribers)}
	end.

handle_response(Ref, EndpointPid, _Message=#{code:={ok, 'Continue'}, options:=Options1}, 
	State=#state{req_refs=ReqRefs, block_regs=BlockRegs}) ->
	case find_ref(Ref, ReqRefs) of
		undefined -> {noreply, State};
		#req{type=Type, method=Method, options=Options2, content=Content, req_ref=ReqRef, ep_id=EpID} = Req ->
			{Num, true, Size} = coap_message:get_option('Block1', Options1),
			{ok, Ref2, BlockKey} = request_block(EpID, EndpointPid, Type, Method, Options2, {Num+1, false, Size}, Content),
			{ReqRefs2, BlockRegs2} = update_block_transfer_status(EndpointPid, BlockKey, Ref, Ref2, ReqRefs, BlockRegs),
			State2 = case Ref of
				ReqRef -> State#state{req_refs=store_ref(Ref2, Req, ReqRefs2)};
				_ -> State#state{req_refs=store_ref(Ref2, Req, delete_ref(Ref, ReqRefs2))}
			end,
			{noreply, State2#state{block_regs=BlockRegs2}}
	end;

handle_response(Ref, EndpointPid, Message=#{code:={ok, Code}, options:=Options1, payload:=Data}, 
	State=#state{req_refs=ReqRefs, block_regs=BlockRegs, subscribers=Subscribers}) ->
	case find_ref(Ref, ReqRefs) of
		undefined -> 
			io:format("unknown response: ~p~n", [Message]),
			{noreply, State};
		#req{type=Type, method=Method, options=Options2, fragment=Fragment, req_ref=ReqRef, reply_pid=ReplyPid, 
			block_obseq=Obseq, obs_key=Key, block_key=BlockKey, ep_id=EpID} = Req ->
            N = case coap_message:get_option('Observe', Options1) of
            	undefined -> Obseq;	% Obseq = undefined by default
            	Else -> Else
		    end,
		    % Note after receiving a notification we cancel any ongoing block transfer 
			% This eliminates the possiblilty that multiple block transfers exist 
			% and thus a potential mix up of old & new blocks of the (changed) resource
		    % update_block_transfer_status(EndpointPid, BlockOrLastRef, Ref),
			case coap_message:get_option('Block2', Options1) of
		        {Num, true, Size} ->
		        	% more blocks follow, ask for more
		        	% no payload for requests with Block2 with NUM != 0
		        	{ok, Ref2} = ecoap_endpoint:send(EndpointPid,
		            	ecoap_request:request(Type, Method, coap_message:add_option('Block2', {Num+1, false, Size}, Options2))),
		            NewFragment = <<Fragment/binary, Data/binary>>,
		            % What we do here:
        			% 1. If this is the first block of a blockwise transfer as an observe notification
		    		% 	 We remember the observe seq number here because following requests will be without observe option
		            % 2. Cancel ongoing blockwise transfer, if any
		            % 3. Update block_key filed of original request 
		            BlockKey2 = case BlockKey of 
		            	undefined -> {EpID, coap_message:get_option('Uri-Path', Options2)};
		            	Other -> Other
		            end,
        			{ReqRefs2, BlockRegs2} = update_block_transfer_status(EndpointPid, BlockKey2, Ref, Ref2, ReqRefs, BlockRegs),
        			Req2 = Req#req{fragment=NewFragment, block_obseq=N, block_key=BlockKey2},
        			State2 = case Ref of
        				ReqRef -> State#state{req_refs=store_ref(ReqRef, Req#req{block_key=BlockKey2}, store_ref(Ref2, Req2, ReqRefs2))};
        				_ -> State#state{req_refs=store_ref(Ref2, Req2, delete_ref(Ref, ReqRefs2))}
        			end,
		            {noreply, State2#state{block_regs=BlockRegs2}};
		        _Else ->
		        	% not segmented	
		        	Res = return_response({ok, Code}, Message#{payload:= <<Fragment/binary, Data/binary>>}),
		            SubPids = get_sub_pids(Key, Subscribers),
		            % It will be a blockwise transfer observe notification if N != undefined
		            ok = send_response(ReplyPid, ReqRef, Key, N, SubPids, Res),
		            ReqRefs2 = case Ref of
		            	ReqRef -> 
		            		case N of
		            			undefined -> delete_ref(Ref, ReqRefs);
		            			_ -> ReqRefs
		            		end;
		            	_ ->
		            		delete_ref(Ref, ReqRefs)
		            end,
		            {noreply, State#state{req_refs=ReqRefs2, block_regs=delete_ref(BlockKey, BlockRegs)}}
			end
	end;       							

handle_response(Ref, _EndpointPid, Message=#{code:={error, _Code}}, State) ->
	handle_error(Ref, Message, State).

handle_error(Ref, Error, State=#state{req_refs=ReqRefs, obs_regs=ObsRegs, block_regs=BlockRegs, subscribers=Subscribers}) ->
	case find_ref(Ref, ReqRefs) of
		undefined -> {noreply, State};
		#req{req_ref=ReqRef, reply_pid=ReplyPid, obs_key=Key, block_key=BlockKey} ->
			Res = case Error of
					#{code:={error, Code}} -> return_response({error, Code}, Error);
					_ -> {error, Error}
			end,
			SubPids = get_sub_pids(Key, Subscribers),
		    ok = send_response(ReplyPid, ReqRef, Key, undefined, SubPids, Res),
			% Make sure we remove any observe relation and info of request related to the error
			% Though it is enough to remove req info just using Ref as key, since for any ordinary message exchange
			% info of last req is always cleaned. Howerver one exception is observe because info of origin observe req is kept until
			% it gets cancelled. Therefore when receiving an error during an observe notification blockwise transfer, we need to clean 
			% both info of last req (referenced by Ref) and info of origin observe req (referenced by ReqRef).
			{noreply, State#state{req_refs=delete_ref(Ref, delete_ref(ReqRef, ReqRefs)), 
								  obs_regs=delete_ref(Key, ObsRegs), block_regs=delete_ref(BlockKey, BlockRegs)}}
	end.

handle_ack(Ref, State=#state{req_refs=ReqRefs, subscribers=Subscribers}) ->
	case find_ref(Ref, ReqRefs) of
		undefined -> {noreply, State};
		#req{req_ref=ReqRef, reply_pid=ReplyPid, obs_key=Key} ->
			SubPids = get_sub_pids(Key, Subscribers),
			ok = send_response(ReplyPid, ReqRef, Key, undefined, SubPids, {separate, Ref}),
			{noreply, State}
	end.

do_cancel_request(EndpointPid, Ref) ->
	ok = ecoap_endpoint:cancel_request(EndpointPid, Ref).

find_ref(Ref, Refs) ->
	case maps:find(Ref, Refs) of
		error -> undefined;
		{ok, Val} -> Val
	end.

store_ref(Ref, Val, Refs) ->
	maps:put(Ref, Val, Refs).

delete_ref(Ref, Refs) ->
	maps:remove(Ref, Refs).

get_sub_pids(Key, Subscribers) ->
	lists:foldl(fun({{Pid, ObsKey}, _, _}, Acc) ->
					if ObsKey =:= Key -> [Pid | Acc]; true -> Acc end
			end, [], Subscribers).

-spec send_response(ReplyPid, ReqRef, ObsKey, Obseq, SubPids, Res) -> ok when
		ReplyPid :: pid(),
		ReqRef :: reference(),
		ObsKey :: observe_key(),
		Obseq :: non_neg_integer() | undefined,
		SubPids :: [pid()],
		Res :: response().

send_response(ReplyPid, ReqRef, undefined, _Obseq, _SubPids, Res) ->
	ReplyPid ! {coap_response, ReqRef, self(), Res},
	ok;
send_response(ReplyPid, ReqRef, ObsKey, Obseq, SubPids, Res) ->
	case Obseq of
		undefined -> self() ! {remove_observe_ref, ObsKey, ReplyPid}, ok;
		_Else -> ok
	end,
	[begin Pid ! {coap_notify, ReqRef, self(), Obseq, Res}, ok end || Pid <- SubPids],
	ok.

return_response({ok, Code}, #{payload:=Payload, options:=Options}) ->
    {ok, Code, Payload, Options};
return_response({error, Code}, #{payload:= <<>>}) ->
    {error, Code};
return_response({error, Code}, #{payload:=Payload, options:=Options}) ->
    {error, Code, Payload, Options}.
