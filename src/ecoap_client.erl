-module(ecoap_client).
-behaviour(gen_server).

%% API.
-export([start_link/0]).
-export([close/1]).
%% ping the server
-export([ping/2]).
%% sync request
-export([request/3, request/4, request/5]).
%% async request
-export([async_request/3, async_request/4, async_request/5, cancel_async_request/2]).
%% observe
-export([observe/2, observe/3, unobserve/2, unobserve/3]).
%% utilities
-export([set_con/1, set_non/1, get_reqrefs/1]).

%% gen_server.
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-record(state, {
	sock_pid = undefined :: pid(),
	req_refs = undefined :: #{reference() => req()},
	obs_regs = undefined :: #{observe_key() => reference()},
	% block_refs maps origin req reference with subsequent req reference within the same blockwise transfer
	block_refs = undefined :: #{reference() => reference()},
	msg_type = 'CON' :: 'CON' | 'NON'
}).

-record(req, {
	method = undefined :: undefined | coap_method(),
	options = [] :: optionset(),
	% token is only used for observe/unobserve
	token = <<>> :: binary(),
	content = undefined :: undefined | coap_content(),
	fragment = <<>> :: binary(),
	from = undefined :: undefined | from(),
	client_ref = undefined :: undefined | reference(),
	client_pid = undefined :: pid(),
	block_obseq = undefined :: undefined | non_neg_integer(),
	ongoing_block = undefined :: undefined | reference(),
	obs_key = undefined :: undefined | observe_key(),
	ep_id = undefined :: ecoap_socket:coap_endpoint_id()
}).

-define(TOKEN_LENGTH, 4). % shall be at least 32 random bits

-include_lib("ecoap_common/include/coap_def.hrl").

-type from() :: {pid(), term()}.
-type req() :: #req{}.
-type request_content() :: coap_content() | binary() | list().
-type response() :: {ok, success_code(), coap_content()} | {error, error_code()} | {error, error_code(), coap_content()} | {separate, reference()}.
-type observe_response() :: {reference(), non_neg_integer(), response()} | response().
-type observe_key() :: {list(), atom() | non_neg_integer()}.
-opaque state() :: #state{}.
-export_type([state/0]).

%% API.

-spec start_link() -> {ok, pid()}.
start_link() ->
	gen_server:start_link(?MODULE, [], []).

-spec close(pid()) -> ok.
close(Pid) ->
	gen_server:cast(Pid, shutdown).

-spec ping(pid(), list()) -> ok | error.
ping(Pid, Uri) ->
	{EpID, _Path, _Query} = resolve_uri(Uri),
	case send_request(Pid, EpID, ping, self()) of
		{error, 'RST'} -> ok;
		_Else -> error
	end.

% Start an observe relation to a specific resource

% If the observe relation is established sucessfully, this function returns the first notification as {ClientRef, N, Res}
% where ClientRef is the reference used to identify following notifications, N is the initial observe sequence number and Res is the response content.
% If the resource is not observable, the function just returns the response as if it was from a plain GET request.
% If the request time out, this function returns {error, timeout}.

% Following notifications will be sent to the caller process as messages in form of {coap_notify, ClientRef, Pid, N, Res}
% where ClientRef is the reference, Pid is the ecoap_client pid, N is the observe sequence number and Res is the response content.
% If some error happened in server side, e.g. a reset/error code is received during observing
% the response is sent to the caller process as message in form of {async_response, ClientRef, Pid, Res} where Res is {error, _}.

% If the ecoap_client process crashed during the calll, the call fails with reason noproc.

-spec observe(pid(), list()) -> observe_response().
observe(Pid, Uri) ->
	observe(Pid, Uri, []).

-spec observe(pid(), list(), optionset()) -> observe_response().
observe(Pid, Uri, Options) ->
	{EpID, Req} = assemble_request('GET', Uri, coap_message_utils:append_option('Observe', 0, Options), <<>>),
	Accpet = coap_message_utils:get_option('Accpet', Options),
	Key = {Uri, Accpet},
	MonitorRef = erlang:monitor(process, Pid),
	{ok, ClientRef} = gen_server:call(Pid, {start_observe, Key, EpID, Req, self()}),
	receive 
		% Server does not support observing the resource or an error happened
		{async_response, ClientRef, Pid, Res} -> 
			erlang:demonitor(MonitorRef, [flush]),
			% We need to remove the observe reference 
			remove_observe_ref(Pid, Key),
			Res;
		{coap_notify, ClientRef, Pid, N, Res} -> 
			erlang:demonitor(MonitorRef, [flush]),
			{ClientRef, N, Res};
		{'DOWN', MonitorRef, process, _Pid, _Reason} ->
			exit(noproc)
	end.

% Cancel an observe relation to a specific resource

% If unobserve resource succeed, the function returns the response as if it was from a plain GET request;
% If the request time out, this function returns {error, timeout}.
% If no matching observe relation exists, the function returns {error, no_observe}.
% note observe relation is matched against URI and accept content-format;
% If the ecoap_client process crashed during the call, the call fails with reason noproc.

% TODO: unobserve(Pid, Ref, ETag)

-spec unobserve(pid(), reference()) -> response() | {error, no_observe}.
unobserve(Pid, Ref) ->
	unobserve(Pid, Ref, <<>>).

-spec unobserve(pid(), reference(), binary()) -> response() | {error, no_observe}.
unobserve(Pid, Ref, ETag) ->
	MonitorRef = erlang:monitor(process, Pid),
	case gen_server:call(Pid, {cancel_observe, Ref, ETag}) of
		{ok, ClientRef} ->
			receive 
				{async_response, ClientRef, Pid, Res} -> 
					erlang:demonitor(MonitorRef, [flush]),
					Res;
				{'DOWN', MonitorRef, process, _Pid, _Reason} -> 
					exit(noproc)
			end;
		Else -> Else
	end.

%% Note that options defined in Content will overwrite the same ones defined in Options
%% But if options in Content are with their default value 'undefined' then they will not be used
%% Also only confirmable requests are supported for now.

-spec request(pid(), coap_method(), list()) -> response().
request(Pid, Method, Uri) ->
	request(Pid, Method, Uri, #coap_content{}, []).

-spec request(pid(), coap_method(), list(), request_content()) -> response().
request(Pid, Method, Uri, Content) -> 
	request(Pid, Method, Uri, Content, []).

-spec request(pid(), coap_method(), list(), request_content(), optionset()) -> response().
request(Pid, Method, Uri, Content, Options) ->
	{EpID, Req} = assemble_request(Method, Uri, Options, Content),
	send_request(Pid, EpID, Req, self()).

-spec async_request(pid(), coap_method(), list()) -> {ok, reference()}.
async_request(Pid, Method, Uri) ->
	async_request(Pid, Method, Uri, #coap_content{}, []).

-spec async_request(pid(), coap_method(), list(), request_content()) -> {ok, reference()}.
async_request(Pid, Method, Uri, Content) -> 
	async_request(Pid, Method, Uri, Content, []).

-spec async_request(pid(), coap_method(), list(), request_content(), optionset()) -> {ok, reference()}.
async_request(Pid, Method, Uri, Content, Options) ->
	{EpID, Req} = assemble_request(Method, Uri, Options, Content),
	send_request_async(Pid, EpID, Req, self()).

% Note this function only cancel an async request that has not been responded yet, e.g. a long term seperate response
% It can also be used to cancel an observe relation reactively, 
% i.e. cancel it by removing token info and let next notification be rejected
% It can not be used to cancel a blockwise transfer if at least one block has transferred successfully because 
% each block transfer is a completely new message exchange
-spec cancel_async_request(pid(), reference()) -> ok | {error, no_request}.
cancel_async_request(Pid, Ref) ->
	gen_server:call(Pid, {cancel_async_request, Ref}).

-spec set_con(pid()) -> ok.
set_con(Pid) -> gen_server:call(Pid, {set_msg_type, 'CON'}).

-spec set_non(pid()) -> ok.
set_non(Pid) -> gen_server:call(Pid, {set_msg_type, 'NON'}).

% utility function for test purpose
-spec get_reqrefs(pid()) -> map().
get_reqrefs(Pid) -> gen_server:call(Pid, get_reqrefs).

assemble_request(Method, Uri, Options, Content) ->
	{EpID, Path, Query} = resolve_uri(Uri),
	Options2 = coap_message_utils:append_option('Uri-Query', Query, coap_message_utils:append_option('Uri-Path', Path, Options)),
	{EpID, {Method, Options2, convert_content(Content)}}.

send_request(Pid, EpID, Req, ClientPid) ->
	% set timeout to infinity because coap_endpoint will always return a response, 
	% i.e. an ordinary response or {error, timeout} when server does not respond to a confirmable request
	gen_server:call(Pid, {send_request, EpID, Req, ClientPid}, infinity).

send_request_async(Pid, EpID, Req, ClientPid) -> 
	gen_server:call(Pid, {send_request_async, EpID, Req, ClientPid}).

remove_observe_ref(Pid, Key) ->
	gen_server:cast(Pid, {remove_observe_ref, Key}).

%% gen_server.

init([]) ->
	{ok, SockPid} = ecoap_socket:start_link(),
	{ok, #state{sock_pid=SockPid, req_refs=maps:new(), obs_regs=maps:new(), block_refs=maps:new()}}.

handle_call({send_request, EpID, ping, ClientPid}, From, State=#state{sock_pid=SockPid, req_refs=ReqRefs}) ->
	{ok, EndpointPid} = ecoap_socket:get_endpoint(SockPid, EpID),
	{ok, Ref} = coap_endpoint:ping(EndpointPid),
	{noreply, State#state{req_refs=store_ref(Ref, #req{from=From, client_pid=ClientPid, ep_id=EpID}, ReqRefs)}};

handle_call({send_request, EpID, {Method, Options, Content}, ClientPid}, From, State=#state{sock_pid=SockPid, req_refs=ReqRefs, msg_type=Type}) ->
	{ok, EndpointPid} = ecoap_socket:get_endpoint(SockPid, EpID),
	{ok, Ref} = request_block(EndpointPid, Type, Method, Options, Content),
	Req = #req{method=Method, options=Options, content=Content, from=From, client_pid=ClientPid, ep_id=EpID},
	{noreply, State#state{req_refs=store_ref(Ref, Req, ReqRefs)}};

handle_call({send_request_async, EpID, {Method, Options, Content}, ClientPid}, _From, State=#state{sock_pid=SockPid, req_refs=ReqRefs, msg_type=Type}) ->
	{ok, EndpointPid} = ecoap_socket:get_endpoint(SockPid, EpID),
	{ok, Ref} = request_block(EndpointPid, Type, Method, Options, Content),
	Req = #req{method=Method, options=Options, content=Content, client_ref=Ref, client_pid=ClientPid, ep_id=EpID},
	{reply, {ok, Ref}, State#state{req_refs=store_ref(Ref, Req, ReqRefs)}};

handle_call({cancel_async_request, Ref}, _From, State=#state{sock_pid=SockPid, req_refs=ReqRefs, block_refs=BlockRefs, obs_regs=ObsRegs}) ->
% cancel async request in following cases:
% 1. ordinary req, including non req, separate res, observe con/non req
% 2. blockwise transfer for both con and non
% 3. blockwise transfer for both con and non, during an observe
	case {find_ref(Ref, ReqRefs), find_ref(Ref, BlockRefs)} of
		{undefined, undefined} -> 
			% no req exist
			{reply, {error, no_request}, State};
		{undefined, SubRef} ->
			% found ordinary blockwise transfer
			#req{ep_id=EpID} = find_ref(SubRef, ReqRefs),
			{ok, EndpointPid} = ecoap_socket:get_endpoint(SockPid, EpID),
			ok = coap_endpoint:remove_token(EndpointPid, SubRef),
			{reply, ok, State#state{req_refs=delete_ref(SubRef, ReqRefs), block_refs=delete_ref(Ref, BlockRefs)}};
		{#req{ep_id=EpID, obs_key=Key}, undefined} ->
			% found ordinary req or observe req without blockwise transfer
			{ok, EndpointPid} = ecoap_socket:get_endpoint(SockPid, EpID),
			ok = coap_endpoint:remove_token(EndpointPid, Ref),
			{reply, ok, State#state{req_refs=delete_ref(Ref, ReqRefs), obs_regs=delete_ref(Key, ObsRegs)}};
		{#req{ep_id=EpID, obs_key=Key}, SubRef} ->
			% found observe req with blockwise transfer
			{ok, EndpointPid} = ecoap_socket:get_endpoint(SockPid, EpID),
			ok = coap_endpoint:remove_token(EndpointPid, Ref),
			ok = coap_endpoint:remove_token(EndpointPid, SubRef),
			{reply, ok, State#state{req_refs=delete_ref(Ref, delete_ref(SubRef, ReqRefs)), block_refs=delete_ref(Ref, BlockRefs), obs_regs=delete_ref(Key, ObsRegs)}}
	end;

handle_call({start_observe, Key, EpID, {Method, Options, _Content}, ClientPid}, _From,
	State=#state{sock_pid=SockPid, req_refs=ReqRefs, obs_regs=ObsRegs, msg_type=Type}) ->
	OldRef = find_ref(Key, ObsRegs),
	Token = case find_ref(OldRef, ReqRefs) of
				undefined -> coap_endpoint:generate_token(?TOKEN_LENGTH);
				#req{token=OldToken} -> OldToken
			end,
	{ok, EndpointPid} = ecoap_socket:get_endpoint(SockPid, EpID),
	{ok, Ref} = coap_endpoint:send(EndpointPid,  
					coap_message_utils:set_token(Token,
						coap_message_utils:request(Type, Method, <<>>, Options))),	
	Options2 = coap_message_utils:remove_option('Observe', Options),
	Req = #req{method=Method, options=Options2, token=Token, client_ref=Ref, client_pid=ClientPid, obs_key=Key, ep_id=EpID},
	{reply, {ok, Ref}, State#state{obs_regs=store_ref(Key, Ref, ObsRegs), req_refs=store_ref(Ref, Req, delete_ref(OldRef, ReqRefs))}};

handle_call({cancel_observe, Ref, ETag}, _From, State=#state{sock_pid=SockPid, req_refs=ReqRefs, obs_regs=ObsRegs, msg_type=Type}) ->
	case find_ref(Ref, ReqRefs) of
		undefined -> {reply, {error, no_observe}, State};
		#req{method=Method, options=Options, token=Token, obs_key=Key, ep_id=EpID, client_pid=ClientPid} ->
			Options2 = coap_message_utils:put_option('ETag', [ETag], Options),
			{ok, EndpointPid} = ecoap_socket:get_endpoint(SockPid, EpID),
			{ok, Ref2} = coap_endpoint:send(EndpointPid,  
							coap_message_utils:set_token(Token, 
								coap_message_utils:request(Type, Method, <<>>, Options2))),
			Options3 = coap_message_utils:remove_option('Observe', Options2),
			Req = #req{method=Method, options=Options3, token=Token, client_ref=Ref2, client_pid=ClientPid, ep_id=EpID},
			{reply, {ok, Ref2}, State#state{obs_regs=delete_ref(Key, ObsRegs), req_refs=store_ref(Ref2, Req, delete_ref(Ref, ReqRefs))}}
	end;

handle_call({set_msg_type, Type}, _From, State) ->
	{reply, ok, State#state{msg_type=Type}};

handle_call(get_reqrefs, _From, State=#state{req_refs=ReqRefs}) ->
	{reply, ReqRefs, State};

handle_call(_Request, _From, State) ->
	{noreply, State}.

handle_cast({remove_observe_ref, Key}, State=#state{obs_regs=ObsRegs, req_refs=ReqRefs}) ->
	{noreply, State#state{obs_regs=delete_ref(Key, ObsRegs), req_refs=delete_ref(find_ref(Key, ObsRegs), ReqRefs)}};

handle_cast(shutdown, State) ->
	{stop, normal, State};
	
handle_cast(_Msg, State) ->
	{noreply, State}.

% response arrived as a separate CON msg
handle_info({coap_response, _EpID, EndpointPid, Ref, Message=#coap_message{type='CON'}}, State) ->
	{ok, _} = coap_endpoint:send(EndpointPid, coap_message_utils:ack(Message)),
	handle_response(Ref, EndpointPid, Message, State);

handle_info({coap_response, _EpID, EndpointPid, Ref, Message}, State) ->
	handle_response(Ref, EndpointPid, Message, State);

% handle separate response acknowledgement
handle_info({coap_ack, _EpID, _EndpointPid, Ref}, State) ->
	handle_ack(Ref, State);

% handle RST and timeout
handle_info({coap_error, _EpID, _EndpointPid, Ref, Error}, State) ->
	handle_error(Ref, Error, State);

handle_info(_Info, State) ->
	{noreply, State}.

terminate(_Reason, #state{sock_pid=SockPid}) ->
	[coap_endpoint:close(Pid) || Pid <- ecoap_socket:get_all_endpoints(SockPid)],
	ok = ecoap_socket:close(SockPid),
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%% Internal

request_block(EndpointPid, Type, Method, ROpt, Content) ->
    request_block(EndpointPid, Type, Method, ROpt, undefined, Content).

request_block(EndpointPid, Type, Method, ROpt, Block1, Content) ->
    coap_endpoint:send(EndpointPid, coap_message_utils:set_content(Content, Block1,
        coap_message_utils:request(Type, Method, <<>>, ROpt))).

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
			{Num, true, Size} = coap_message_utils:get_option('Block1', Options1),
			{ok, Ref2} = request_block(EndpointPid, Type, Method, Options2, {Num+1, false, Size}, Content),
			{noreply, State#state{req_refs=store_ref(Ref2, Req, delete_ref(Ref, ReqRefs))}}
	end;

handle_response(Ref, EndpointPid, Message=#coap_message{code={ok, Code}, options=Options1, payload=Data}, 
	State = #state{req_refs=ReqRefs, block_refs=BlockRefs, msg_type=Type}) ->
	case find_ref(Ref, ReqRefs) of
		undefined -> 
			io:format("unknown response: ~p~n", [Message]),
			{noreply, State};
		#req{method=Method, options=Options2, fragment=Fragment, client_ref=ClientRef, 
			client_pid=ClientPid, from=From, block_obseq=Obseq, ongoing_block=OngoingBlock} = Req ->
			case coap_message_utils:get_option('Block2', Options1) of
		        {Num, true, Size} ->
		            % more blocks follow, ask for more
		            % no payload for requests with Block2 with NUM != 0
		            {ok, Ref2} = coap_endpoint:send(EndpointPid,
		            	coap_message_utils:request(Type, Method, <<>>, coap_message_utils:append_option('Block2', {Num+1, false, Size}, Options2))),
		            NewFragment = <<Fragment/binary, Data/binary>>,
		            case coap_message_utils:get_option('Observe', Options1) of
		            	undefined ->
		            		% We need to clean up intermediate requests info during a blockwise transfer and only keep the newest one
		            		{noreply, State#state{req_refs=store_ref(Ref2, Req#req{fragment=NewFragment, ongoing_block=Ref2}, delete_ref(Ref, ReqRefs)), block_refs=update_block_refs(ClientRef, Ref2, BlockRefs)}};
		            	N ->
		            		% This is the first response of a blockwise transfer when observing certain resource
		            		% We remember the observe seq number here because following requests will be normal ones
		            		% Note after receiving a notification we delete any ongoing block transfer 
		            		% (info of the last request with block option) before continuing and always start a fresh block transfer
		            		% This eliminates the possiblilty that multiple block transfers exist 
		            		% and thus a potential mix up of old & new blocks of the (changed) resource
		            		{noreply, State#state{req_refs=store_ref(Ref2, Req#req{fragment=NewFragment, block_obseq=N, ongoing_block=Ref2}, delete_ref(OngoingBlock, ReqRefs)), block_refs=update_block_refs(ClientRef, Ref2, BlockRefs)}}	
		            end;
		        _Else ->
		            % not segmented
		            Res = return_response({ok, Code}, Message#coap_message{payload= <<Fragment/binary, Data/binary>>}),
			        case coap_message_utils:get_option('Observe', Options1) of
			        	undefined ->
			        		% It will be a blockwise transfer observe notification if Obseq is not undefined
			        		case Obseq of
			        			undefined -> 
			        				ok = send_response(From, ClientPid, ClientRef, Res);
			        			Num ->
			        				ok = send_notify(ClientPid, ClientRef, Num, Res)
			        		end,
			        		{noreply, State#state{req_refs=delete_ref(Ref, ReqRefs), block_refs=delete_ref(ClientRef, BlockRefs)}};
			        	Num ->
			        		ok = send_notify(ClientPid, ClientRef, Num, Res),
			        		{noreply, State}
			        end
		    end
    end;

handle_response(Ref, _EndpointPid, Message=#coap_message{code={error, _Code}}, State) ->
	handle_error(Ref, Message, State).

handle_error(Ref, Error, State=#state{req_refs=ReqRefs, obs_regs=ObsRegs}) ->
	case find_ref(Ref, ReqRefs) of
		undefined -> {noreply, State};
		#req{client_ref=ClientRef, from=From, client_pid=ClientPid, obs_key=Key} ->
			Res = case Error of
					#coap_message{code={error, Code}} -> return_response({error, Code}, Error);
					_ -> {error, Error}
			end,
		    ok = send_response(From, ClientPid, ClientRef, Res),
			% Make sure we remove any observe relation and info of request related to the error
			% Note: Though it is enough to remove req info just using Ref as key, since for any ordinary message exchange
			% info of last req is always cleaned. Howerver one exception is observe as info of origin observe req is kept until
			% it get cancelled. Therefore when receiving an error during an observe notification blockwise transfer, we need to clean 
			% both info of last req (referenced by Ref) and info of origin observe req (referenced by ClientRef).
			{noreply, State#state{req_refs=delete_ref(Ref, delete_ref(ClientRef, ReqRefs)), obs_regs=delete_ref(Key, ObsRegs)}}
	end.

handle_ack(Ref, State=#state{req_refs=ReqRefs}) ->
	case find_ref(Ref, ReqRefs) of
		undefined -> {noreply, State};
		#req{client_ref=ClientRef, from=From, client_pid=ClientPid} = Req ->
			ok = send_response(From, ClientPid, ClientRef, {separate, Ref}),
			{noreply, State#state{req_refs=store_ref(Ref, Req#req{from=undefined, client_ref=Ref}, ReqRefs)}}
	end.

send_notify(ClientPid, ClientRef, Obseq, Res) ->
    ClientPid ! {coap_notify, ClientRef, self(), Obseq, Res},
    ok.

update_block_refs(undefined, _, BlockRefs) -> BlockRefs;
update_block_refs(InitRef, NewRef, BlockRefs) ->
	store_ref(InitRef, NewRef, BlockRefs).

find_ref(Ref, Refs) ->
	case maps:find(Ref, Refs) of
		error -> undefined;
		{ok, Val} -> Val
	end.

store_ref(Ref, Val, Refs) ->
	maps:put(Ref, Val, Refs).

delete_ref(Ref, Refs) ->
	maps:remove(Ref, Refs).

send_response(undefined, ClientPid, ClientRef, Res) ->
    ClientPid ! {async_response, ClientRef, self(), Res},
    ok;
send_response(From, _, _, Res) ->
    _ = gen_server:reply(From, Res),
    ok.

return_response({ok, Code}, Message) ->
    {ok, Code, coap_message_utils:get_content(Message)};
return_response({error, Code}, #coap_message{payload= <<>>}) ->
    {error, Code};
return_response({error, Code}, Message) ->
    {error, Code, coap_message_utils:get_content(Message)}.

convert_content(Content = #coap_content{}) -> Content;
convert_content(Content) when is_binary(Content) -> #coap_content{payload=Content};
convert_content(Content) when is_list(Content) -> #coap_content{payload=list_to_binary(Content)}.

resolve_uri(Uri) ->
    {ok, {_Scheme, _UserInfo, Host, PortNo, Path, Query}} =
        http_uri:parse(Uri, [{scheme_defaults, [{coap, 5683}]}]),
    {ok, PeerIP} = inet:getaddr(Host, inet),
    {{PeerIP, PortNo}, split_path(Path), split_query(Query)}.

split_path([]) -> [];
split_path([$/]) -> [];
split_path([$/ | Path]) -> split_segments(Path, $/, []).

split_query([]) -> [];
split_query([$? | Path]) -> split_segments(Path, $&, []).

split_segments(Path, Char, Acc) ->
    case string:rchr(Path, Char) of
        0 ->
            [make_segment(Path) | Acc];
        N when N > 0 ->
            split_segments(string:substr(Path, 1, N-1), Char,
                [make_segment(string:substr(Path, N+1)) | Acc])
    end.

make_segment(Seg) ->
    list_to_binary(http_uri:decode(Seg)).
