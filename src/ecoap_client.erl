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
-export([get_reqrefs/1, get_obsregs/1, get_blockrefs/1]).
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
	% block_refs maps origin req reference with subsequent req reference within the same blockwise transfer
	block_refs = #{} :: #{reference() => reference()},
	obs_regs = #{} :: #{observe_key() => binary()},
	subscribers = [] :: [{{pid(), observe_key()}, reference(), reference()}],
	msg_type = 'CON' :: 'CON'
}).

-record(req, {
	method = undefined :: undefined | coap_method(),
	options = #{} :: optionset(),
	token = <<>> :: binary(),
	content = undefined :: undefined | coap_content(),
	fragment = <<>> :: binary(),
	req_ref = undefined :: undefined | reference(),
	reply_pid = undefined :: pid(),
	block_obseq = undefined :: undefined | non_neg_integer(),
	obs_key = undefined :: undefined | observe_key(),
	ep = undefined :: pid()
}).

-include_lib("ecoap_common/include/coap_def.hrl").

-type req() :: #req{}.
-type request_content() :: binary() | coap_content().
-type response() :: {ok, success_code(), coap_content()} | 
					{error, timeout} |
					{error, error_code()} | 
					{error, error_code(), coap_content()} | 
					{separate, reference()}.
-type observe_response() :: {ok, reference(), pid(), non_neg_integer(), success_code(), coap_content()} | response().
-type observe_key() :: {binary(), atom() | non_neg_integer()}.
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
	{_Scheme, _Host, EpID, _Path, _Query} = coap_utils:decode_uri(Uri),
	case send_request(Pid, EpID, {ping, #{}, undefined}, infinity) of
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

-spec request(pid(), coap_method(), string()) -> response().
request(Pid, Method, Uri) ->
	request(Pid, Method, Uri, #coap_content{}, #{}, infinity).

-spec request(pid(), coap_method(), string(), request_content()) -> response().
request(Pid, Method, Uri, Content) -> 
	request(Pid, Method, Uri, Content, #{}, infinity).

-spec request(pid(), coap_method(), string(), request_content(), optionset()) -> response().
request(Pid, Method, Uri, Content, Options) ->
	request(Pid, Method, Uri, Content, Options, infinity).

-spec request(pid(), coap_method(), string(), request_content(), optionset(), infinity | non_neg_integer()) -> response().
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

-spec async_request(pid(), coap_method(), string()) -> {ok, reference()}.
async_request(Pid, Method, Uri) ->
	async_request(Pid, Method, Uri, #coap_content{}, #{}).

-spec async_request(pid(), coap_method(), string(), request_content()) -> {ok, reference()}.
async_request(Pid, Method, Uri, Content) -> 
	async_request(Pid, Method, Uri, Content, #{}).

-spec async_request(pid(), coap_method(), string(), request_content(), optionset()) -> {ok, reference()}.
async_request(Pid, Method, Uri, Content, Options) ->
	{EpID, Req} = assemble_request(Method, Uri, Options, Content),
	send_request(Pid, EpID, Req).

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

-spec observe(pid(), string(), optionset()) -> observe_response().
observe(Pid, Uri, Options) ->
	{EpID, Key, Req} = assemble_observe_request(Uri, Options),
	% start monitor after we got ReqRef in case the gen_server call crash and we are left with the unused monitor
	{ok, ReqRef} = gen_server:call(Pid, {start_observe, EpID, Key, Req, self()}),
	MonRef = erlang:monitor(process, Pid),
	receive 
		% Server does not support observing the resource or an error happened
		{coap_notify, ReqRef, Pid, undefined, Res} ->
			erlang:demonitor(MonRef, [flush]),
			Res;
		{coap_notify, ReqRef, Pid, N, {ok, Code, Content}} -> 
			erlang:demonitor(MonRef, [flush]),
			{ok, ReqRef, Pid, N, Code, Content};
		{'DOWN', MonRef, process, Pid, Reason} ->
			exit(Reason)
	end.

-spec async_observe(pid(), string()) -> {ok, reference()}.
async_observe(Pid, Uri) ->
	async_observe(Pid, Uri, #{}).

-spec async_observe(pid(), string(), optionset()) -> {ok, reference()}.
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
	unobserve(Pid, Ref, <<>>).

-spec unobserve(pid(), reference(), binary()) -> response() | {error, no_observe}.
unobserve(Pid, Ref, ETag) ->
	case gen_server:call(Pid, {cancel_observe, Ref, ETag}) of
		{ok, ReqRef} ->
			MonRef = erlang:monitor(process, Pid),
			receive 
				{coap_response, ReqRef, Pid, Res} -> 
					erlang:demonitor(MonRef, [flush]),
					Res;
				{'DOWN', MonRef, process, Pid, Reason} -> 
					exit(Reason)
			end;
		Else -> Else
	end.

-spec async_unobserve(pid(), reference()) -> {ok, reference()} | {error, no_observe}.
async_unobserve(Pid, Ref) ->
	async_unobserve(Pid, Ref, <<>>).

-spec async_unobserve(pid(), reference(), binary()) -> {ok, reference()} | {error, no_observe}.
async_unobserve(Pid, Ref, ETag) ->
	gen_server:call(Pid, {cancel_observe, Ref, ETag}).

% -spec set_con(pid()) -> ok.
% set_con(Pid) -> gen_server:call(Pid, {set_msg_type, 'CON'}).

% -spec set_non(pid()) -> ok.
% set_non(Pid) -> gen_server:call(Pid, {set_msg_type, 'NON'}).

-ifdef(TEST).

% utility function for test purpose
-spec get_reqrefs(pid()) -> map().
get_reqrefs(Pid) -> gen_server:call(Pid, get_reqrefs).

-spec get_obsregs(pid()) -> map().
get_obsregs(Pid) -> gen_server:call(Pid, get_obsregs).

-spec get_blockrefs(pid()) -> map().
get_blockrefs(Pid) -> gen_server:call(Pid, get_blockrefs).

-endif.

assemble_request(Method, Uri, Options, Content) ->
	{_Scheme, Host, {PeerIP, PortNo}, Path, Query} = coap_utils:decode_uri(Uri),
	Options2 = coap_utils:add_option('Uri-Path', Path, 
					coap_utils:add_option('Uri-Query', Query,
						coap_utils:add_option('Uri-Host', Host, 
							coap_utils:add_option('Uri-Port', PortNo, Options)))),
	{{PeerIP, PortNo}, {Method, Options2, convert_content(Content)}}.

assemble_observe_request(Uri, Options) ->
	{EpID, Req} = assemble_request('GET', Uri, coap_utils:add_option('Observe', 0, Options), #coap_content{}),
	Accpet = coap_utils:get_option('Accpet', Options),
	Key = {list_to_binary(Uri), Accpet},
	{EpID, Key, Req}.

convert_content(Content=#coap_content{}) -> Content;
convert_content(Content) when is_binary(Content) -> #coap_content{payload=Content}.

% send_request_sync(Pid, EpID, Req, ReplyPid) ->
% 	% set timeout to infinity because ecoap_endpoint will always return a response, 
% 	% i.e. an ordinary response or {error, timeout} when server does not respond to a confirmable request
% 	gen_server:call(Pid, {send_request, sync, EpID, Req, ReplyPid}, infinity).

send_request(Pid, EpID, Req) -> 
	gen_server:call(Pid, {send_request, EpID, Req, self()}).

send_request(Pid, EpID, Req, Timeout) ->
	Tag = make_ref(),
	Caller = self(),
    {Receiver, RecMref} = 
    	erlang:spawn_monitor(
    		% Middleman process. Should be unsensitive to regular
		  	% exit signals. 
		  	fun() ->
				process_flag(trap_exit, true),
				{ok, ReqRef} = gen_server:call(Pid, {send_request, EpID, Req, self()}),
				ToMref = erlang:monitor(process, Pid),
				CallerMref = erlang:monitor(process, Caller),
				receive 
					{coap_response, ReqRef, Pid, Result} ->
						exit({self(), Tag, Result});
					{'DOWN', ToMref, _, _, Reason} ->
						% target process died with Reason and so do we
						exit(Reason);
					{'DOWN', CallerMref, _, _, _} ->
						% Caller exit before request complete 
						% we clean state and sliently give up
			  			cancel_async_request(Pid, ReqRef),
						ok
				after Timeout ->
					cancel_async_request(Pid, ReqRef),
					exit(timeout)
				end
			end),
   	receive
		{'DOWN', RecMref, _, _, {Receiver, Tag, Result}} ->
	    	Result;
		{'DOWN', RecMref, _, _, Reason} ->
	    	check_exit(Reason)
    end.
	
check_exit(timeout) -> {error, timeout};
check_exit(Reason) -> exit(Reason).

%% gen_server.

init([]) ->
	{ok, SockPid} = ecoap_udp_socket:start_link(),
	{ok, #state{sock_pid=SockPid}}.

handle_call({send_request, EpID, {Method, Options, Content}, ReplyPid}, _From, State=#state{sock_pid=SockPid, req_refs=ReqRefs, msg_type=Type}) ->
	{ok, EndpointPid} = get_endpoint(SockPid, EpID),
	{ok, Ref} = case Method of
		ping -> ecoap_endpoint:ping(EndpointPid);
		_ -> request_block(EndpointPid, Type, Method, Options, Content)
	end,
	Req = #req{method=Method, options=Options, content=Content, req_ref=Ref, reply_pid=ReplyPid, ep=EndpointPid},
	{reply, {ok, Ref}, State#state{req_refs=store_ref(Ref, Req, ReqRefs)}};

handle_call({start_observe, EpID, Key, {Method, Options, _Content}, ReplyPid}, _From,
	State=#state{sock_pid=SockPid, req_refs=ReqRefs, obs_regs=ObsRegs, msg_type=Type, subscribers=Subscribers}) ->
	{Token, ObsRegs2} = case find_ref(Key, ObsRegs) of
		undefined -> 
			NewToken = ecoap_endpoint:generate_token(), 
			{NewToken, store_ref(Key, NewToken, ObsRegs)};
		OldToken -> 
			{OldToken, ObsRegs}
	end,
	{ok, EndpointPid} = get_endpoint(SockPid, EpID),
	{ok, Ref} = ecoap_endpoint:send(EndpointPid,  
					coap_utils:set_token(Token,
						coap_utils:request(Type, Method, <<>>, Options))),	
	Options2 = coap_utils:remove_option('Observe', Options),
	Req = #req{method=Method, options=Options2, token=Token, req_ref=Ref, reply_pid=ReplyPid, obs_key=Key, ep=EndpointPid},
	{Subscribers2, ReqRefs2} = case lists:keyfind({ReplyPid, Key}, 1, Subscribers) of
		{{ReplyPid, Key}, _MonRef, ReqRef} ->
			Subs = lists:keyreplace({ReplyPid, Key}, 1,  Subscribers, {{ReplyPid, Key}, _MonRef, Ref}),
			{Subs, store_ref(Ref, Req, delete_ref(ReqRef, ReqRefs))};
		false ->
			{[{{ReplyPid, Key}, erlang:monitor(process, ReplyPid), Ref} | Subscribers], store_ref(Ref, Req, ReqRefs)}
	end,
	{reply, {ok, Ref}, State#state{obs_regs=ObsRegs2, req_refs=ReqRefs2, subscribers=Subscribers2}};

handle_call({cancel_observe, Ref, ETag}, _From, State=#state{req_refs=ReqRefs, obs_regs=ObsRegs, msg_type=Type, subscribers=Subscribers}) ->
	case find_ref(Ref, ReqRefs) of
		#req{method=Method, options=Options, token=Token, obs_key=Key, ep=EndpointPid, reply_pid=ReplyPid} when Key =/= undefined ->
			Options1 = case ETag of <<>> -> Options; Else -> coap_utils:add_option('ETag', [Else], Options) end,
			Options2 = coap_utils:add_option('Observe', 1, Options1),
			{ok, Ref2} = ecoap_endpoint:send(EndpointPid,  
							coap_utils:set_token(Token, 
								coap_utils:request(Type, Method, <<>>, Options2))),
			Options3 = coap_utils:remove_option('Observe', Options2),
			Req = #req{method=Method, options=Options3, token=Token, req_ref=Ref2, reply_pid=ReplyPid, ep=EndpointPid},
			{{ReplyPid, Key}, MonRef, Ref} = Sub = lists:keyfind({ReplyPid, Key}, 1, Subscribers),
			erlang:demonitor(MonRef, [flush]),
			{reply, {ok, Ref2}, State#state{req_refs=store_ref(Ref2, Req, delete_ref(Ref, ReqRefs)),
										    obs_regs=delete_ref(Key, ObsRegs),
											subscribers=lists:delete(Sub, Subscribers)}};
		_Else -> {reply, {error, no_observe}, State}
	end;

% handle_call({set_msg_type, Type}, _From, State) ->
% 	{reply, ok, State#state{msg_type=Type}};

handle_call(get_reqrefs, _From, State=#state{req_refs=ReqRefs}) ->
	{reply, ReqRefs, State};

handle_call(get_obsregs, _From, State=#state{obs_regs=ObsRegs}) ->
	{reply, ObsRegs, State};

handle_call(get_blockrefs, _From, State=#state{block_refs=BlockRefs}) ->
	{reply, BlockRefs, State};

handle_call(_Request, _From, State) ->
	{noreply, State}.

handle_cast({cancel_async_request, Ref}, State) ->
	State2 = cancel_request(Ref, State),
	{noreply, State2};
handle_cast(_Msg, State) ->
	{noreply, State}.

% response arrived as a separate CON msg
handle_info({coap_response, _EpID, EndpointPid, Ref, Message=#coap_message{type='CON'}}, State) ->
	{ok, _} = ecoap_endpoint:send(EndpointPid, coap_utils:ack(Message)),
	handle_response(Ref, EndpointPid, Message, State);

handle_info({coap_response, _EpID, EndpointPid, Ref, Message}, State) ->
	handle_response(Ref, EndpointPid, Message, State);

% handle separate response acknowledgement
handle_info({coap_ack, _EpID, _EndpointPid, Ref}, State) ->
	handle_ack(Ref, State);

% handle RST and timeout
handle_info({coap_error, _EpID, _EndpointPid, Ref, Error}, State) ->
	handle_error(Ref, Error, State);

handle_info({remove_observe_ref, Key, ReplyPid}, State=#state{obs_regs=ObsRegs, req_refs=ReqRefs, subscribers=Subscribers}) ->
	{{ReplyPid, Key}, _MonRef ,ReqRef} = Sub = lists:keyfind({ReplyPid, Key}, 1, Subscribers),
	{noreply, State#state{obs_regs=delete_ref(Key, ObsRegs), 
						  req_refs=delete_ref(ReqRef, ReqRefs),
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

get_endpoint(SockPid, EpID) ->
	{ok, EndpointPid} = ecoap_udp_socket:get_endpoint(SockPid, EpID),
	case ecoap_endpoint:check_alive(EndpointPid) of
		true -> {ok, EndpointPid};
		false -> get_endpoint(SockPid, EpID)
	end.

request_block(EndpointPid, Type, Method, ROpt, Content) ->
    request_block(EndpointPid, Type, Method, ROpt, undefined, Content).

request_block(EndpointPid, Type, Method, ROpt, Block1, Content) ->
    ecoap_endpoint:send(EndpointPid, coap_utils:set_content(Content, Block1,
        coap_utils:request(Type, Method, <<>>, ROpt))).

% function to cancel request(s) using user side request reference
% cancel async request in following cases:
% 1. ordinary req, including non req, separate res, observe con/non req
% 2. blockwise transfer for both con and non
% 3. blockwise transfer for both con and non, during an observe
cancel_request(ReqRef, State=#state{req_refs=ReqRefs, block_refs=BlockRefs, obs_regs=ObsRegs, subscribers=Subscribers}) ->
	case {find_ref(ReqRef, ReqRefs), find_ref(ReqRef, BlockRefs)} of
		{undefined, undefined} -> 
			% no req exist
			State;
		{undefined, SubRef} ->
			% found ordinary blockwise transfer
			#req{ep=EndpointPid} = find_ref(SubRef, ReqRefs),
			do_cancel_request(EndpointPid, SubRef),
			State#state{req_refs=delete_ref(SubRef, ReqRefs), 
						block_refs=delete_ref(ReqRef, BlockRefs)};
		{#req{ep=EndpointPid, obs_key=Key, reply_pid=ReplyPid}, undefined} ->
			% found ordinary req or observe req without blockwise transfer
			do_cancel_request(EndpointPid, ReqRef),
			State#state{req_refs=delete_ref(ReqRef, ReqRefs), 
						obs_regs=delete_ref(Key, ObsRegs), 
						subscribers=lists:keydelete({ReplyPid, Key}, 1, Subscribers)};
		{#req{ep=EndpointPid, obs_key=Key, reply_pid=ReplyPid}, SubRef} ->
			% found observe req with blockwise transfer
			do_cancel_request(EndpointPid, ReqRef),
			do_cancel_request(EndpointPid, SubRef),
			State#state{req_refs=delete_ref(ReqRef, delete_ref(SubRef, ReqRefs)), 
						block_refs=delete_ref(ReqRef, BlockRefs), 
						obs_regs=delete_ref(Key, ObsRegs), 
						subscribers=lists:keydelete({ReplyPid, Key}, 1, Subscribers)}
	end.

% TODO (Solved):
% what happens if we can not detect an already ongoing blockwise transfer for a notification 
% when a new notification for the same token is received while the blockwise transfer is still in progress?
% This may also lead to: already running blockwise transfer(s) might mix up old with new blocks of the (changed) resource.
% NOTE: usually we should not allow multiple blockwise transfers in parallel

% Think about the following case, how should we deal with it

% <-----   CON [MID=8002, T=09c9], 2.05, 2:0/1/16, (observe=2)
% ACK [MID=8002], 0                         ----->
% CON [MID=33807, T=2cedd382e00a0198], GET, /test, 2:1/0/16    ----->
% <-----   ACK [MID=33807, T=2cedd382e00a0198], 2.05, 2:1/1/16
% CON [MID=33808, T=2cedd382e00a0198], GET, /test, 2:2/0/16    ----->

% //////// Overriding notification ////////
% <-----   CON [MID=8003, T=09c9], 2.05, 2:0/1/16, (observe=3)
% ACK [MID=8003], 0                         ----->
% CON [MID=33809, T=7770ba91], GET, /test, 2:1/0/16    ----->
% <-----   ACK [MID=33808, T=2cedd382e00a0198], 2.05, 2:2/0/16
% <-----   ACK [MID=33809, T=7770ba91], 2.05, 2:1/1/16
% CON [MID=33810, T=7770ba91], GET, /test, 2:2/0/16    ----->
% <-----   ACK [MID=33810, T=7770ba91], 2.05, 2:2/0/16

% <-----   CON [MID=8004, T=09c9], 2.05, 2:0/1/16, (observe=4)
% ACK [MID=8004], 0                         ----->
% CON [MID=33811, T=36], GET, /test, 2:1/0/16    ----->

% //////// Overriding notification 2 ////////
% <-----   CON [MID=8005, T=09c9], 2.05, 2:0/1/16, (observe=5)
% ACK [MID=8005], 0                         ----->

% //////// Conflicting notification block ////////
% CON [MID=33812, T=2c8eb312ea], GET, /test, 2:1/0/16    ----->
% <-----   ACK [MID=33811, T=36], 2.05, 2:1/1/16
% <-----   ACK [MID=33812, T=2c8eb312ea], 2.05, 2:1/1/16
% CON [MID=33813, T=2c8eb312ea], GET, /test, 2:2/0/16    ----->
% <-----   ACK [MID=33813, T=2c8eb312ea], 2.05, 2:2/0/16


handle_response(Ref, EndpointPid, _Message=#coap_message{code={ok, 'Continue'}, options=Options1}, 
	State=#state{req_refs=ReqRefs, msg_type=Type}) ->
	case find_ref(Ref, ReqRefs) of
		undefined -> {noreply, State};
		#req{method=Method, options=Options2, content=Content} = Req ->
			{Num, true, Size} = coap_utils:get_option('Block1', Options1),
			{ok, Ref2} = request_block(EndpointPid, Type, Method, Options2, {Num+1, false, Size}, Content),
			{noreply, State#state{req_refs=store_ref(Ref2, Req, delete_ref(Ref, ReqRefs))}}
	end;


handle_response(Ref, EndpointPid, Message=#coap_message{code={ok, Code}, options=Options1, payload=Data}, 
	State = #state{req_refs=ReqRefs, block_refs=BlockRefs, msg_type=Type, subscribers=Subscribers}) ->
	case find_ref(Ref, ReqRefs) of
		undefined -> 
			io:format("unknown response: ~p~n", [Message]),
			{noreply, State};
		#req{method=Method, options=Options2, fragment=Fragment, req_ref=ReqRef, reply_pid=ReplyPid, 
			block_obseq=Obseq, obs_key=Key} = Req ->
            {N, BlockOrLastRef} = case coap_utils:get_option('Observe', Options1) of
            	undefined -> {Obseq, Ref};	% Obseq = undefined by default and Ref is reference to last sent request
            	Else -> {Else, find_ref(ReqRef, BlockRefs)}
		    end,
		    % Note after receiving a notification we cancel any ongoing block transfer 
			% This eliminates the possiblilty that multiple block transfers exist 
			% and thus a potential mix up of old & new blocks of the (changed) resource
		    maybe_cancel_last_block_request(EndpointPid, BlockOrLastRef, Ref),
			case coap_utils:get_option('Block2', Options1) of
		        {Num, true, Size} ->
		        	% more blocks follow, ask for more
		        	% no payload for requests with Block2 with NUM != 0
		        	{ok, Ref2} = ecoap_endpoint:send(EndpointPid,
		            	coap_utils:request(Type, Method, <<>>, coap_utils:add_option('Block2', {Num+1, false, Size}, Options2))),
		            NewFragment = <<Fragment/binary, Data/binary>>,
		            % What we do here:
        			% 1. If this is the first block of a blockwise transfer as an observe notification
		    		% 	 We remember the observe seq number here because following requests will be without observe option
		            % 2. update mapping from origin request to the lastest block request
		            %    and clean up intermediate requests info during a blockwise transfer to only keep the newest one
		            {noreply, State#state{req_refs=store_ref(Ref2, Req#req{fragment=NewFragment, block_obseq=N}, delete_ref(BlockOrLastRef, ReqRefs)), 
		            					          block_refs=update_block_refs(ReqRef, Ref2, BlockRefs)}};
		        _Else ->
		        	% not segmented	
		        	Res = return_response({ok, Code}, Message#coap_message{payload= <<Fragment/binary, Data/binary>>}),
		            SubPids = get_sub_pids(Key, Subscribers),
		            % It will be a blockwise transfer observe notification if N != undefined
		            ok = send_response(ReplyPid, ReqRef, Key, N, SubPids, Res),
					{noreply, State#state{req_refs=delete_ref(BlockOrLastRef, ReqRefs), 
			        							  block_refs=delete_ref(ReqRef, BlockRefs)}}
			end
	end;       							

handle_response(Ref, _EndpointPid, Message=#coap_message{code={error, _Code}}, State) ->
	handle_error(Ref, Message, State).

handle_error(Ref, Error, State=#state{req_refs=ReqRefs, obs_regs=ObsRegs, block_refs=BlockRefs, subscribers=Subscribers}) ->
	case find_ref(Ref, ReqRefs) of
		undefined -> {noreply, State};
		#req{req_ref=ReqRef, reply_pid=ReplyPid, obs_key=Key} ->
			Res = case Error of
					#coap_message{code={error, Code}} -> return_response({error, Code}, Error);
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
								  obs_regs=delete_ref(Key, ObsRegs), block_refs=delete_ref(ReqRef, BlockRefs)}}
	end.

handle_ack(Ref, State=#state{req_refs=ReqRefs, subscribers=Subscribers}) ->
	case find_ref(Ref, ReqRefs) of
		undefined -> {noreply, State};
		#req{req_ref=ReqRef, reply_pid=ReplyPid, obs_key=Key} = Req ->
			SubPids = get_sub_pids(Key, Subscribers),
			ok = send_response(ReplyPid, ReqRef, Key, undefined, SubPids, {separate, Ref}),
			{noreply, State#state{req_refs=store_ref(Ref, Req#req{req_ref=Ref}, ReqRefs)}}
	end.

do_cancel_request(EndpointPid, Ref) ->
	ok = ecoap_endpoint:cancel_request(EndpointPid, Ref).

maybe_cancel_last_block_request(EndpointPid, BlockOrLastRef, Ref) -> 
	case BlockOrLastRef of
		undefined -> ok;
		Ref -> ok;
		% this indicates we recevie a new blockwise observe notification in the middle of last blockwise transfer
		_ -> do_cancel_request(EndpointPid, BlockOrLastRef)
	end.

find_ref(Ref, Refs) ->
	case maps:find(Ref, Refs) of
		error -> undefined;
		{ok, Val} -> Val
	end.

store_ref(Ref, Val, Refs) ->
	maps:put(Ref, Val, Refs).

delete_ref(Ref, Refs) ->
	maps:remove(Ref, Refs).

update_block_refs(undefined, _, BlockRefs) -> BlockRefs;
update_block_refs(InitRef, NewRef, BlockRefs) ->
	store_ref(InitRef, NewRef, BlockRefs).

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

return_response({ok, Code}, Message) ->
    {ok, Code, coap_utils:get_content(Message, extended)};
return_response({error, Code}, #coap_message{payload= <<>>}) ->
    {error, Code};
return_response({error, Code}, Message) ->
    {error, Code, coap_utils:get_content(Message)}.
