-module(ecoap_handler).
-behaviour(gen_server).

%% API.
-export([start_link/2, close/1, notify/2]).

%% gen_server.
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-include("ecoap_message.hrl").
-include("ecoap_content.hrl").

-record(state, {
    endpoint_pid = undefined :: pid(),
    cache_timeout = undefined :: timeout(),
    max_body_size = undefined :: non_neg_integer(),
    max_block_size = undefined :: non_neg_integer(),
    id = undefined :: ecoap_endpoint:handler_id(),
    module = undefined :: module(), 
    insegs = undefined :: {orddict:orddict(), undefined | binary() | non_neg_integer()}, 
    last_response = undefined :: last_response(),
    observer = undefined :: undefined | ecoap_message:coap_message(), 
    obseq = undefined :: non_neg_integer(), 
    obstate = undefined :: term(), 
    timer = undefined :: undefined | reference(),
    uri = undefined :: ecoap_uri:path(),
    prefix = undefined :: undefined | ecoap_uri:path(), 
    suffix = undefined :: undefined | ecoap_uri:path()}).

-type reason() :: binary().
-type observe_ref() :: term().
-type observe_state() :: any().

-type last_response() ::
    undefined |
    {ok, ecoap_message:success_code(), ecoap_content:ecoap_content()} |
    ecoap_message:coap_success() | 
    ecoap_message:coap_error().

-export_type([reason/0]).

%% TODO: 
%% consider method to specify type of sperate response
%% e.g. CON -> Empty ACK -> CON -> Empty ACK, or
%% CON -> Empty ACK -> NON

% called when a client asks for .well-known/core resources
-callback coap_discover(Prefix) -> [LinkFormat] when
    Prefix :: ecoap_uri:path(),
    LinkFormat :: ecoap_core_link:link_format().
-optional_callbacks([coap_discover/1]). 

% GET handler
-callback coap_get(EpID, Prefix, Suffix, Request) -> 
    {ok, Content} | {error, Error} | {error, Error, Reason} when
    EpID :: ecoap_endpoint:ecoap_endpoint_id(),
    Prefix :: ecoap_uri:path(),
    Suffix :: ecoap_uri:path(),
    % Query :: 'query'(),
    Request :: ecoap_message:coap_message(),
    Content :: ecoap_content:ecoap_content(),
    Error :: ecoap_message:error_code(),
    Reason :: reason().
-optional_callbacks([coap_get/4]). 

% FETCH handler
-callback coap_fetch(EpID, Prefix, Suffix, Request) -> 
    {ok, Content} | {error, Error} | {error, Error, Reason} when
    EpID :: ecoap_endpoint:ecoap_endpoint_id(),
    Prefix :: ecoap_uri:path(),
    Suffix :: ecoap_uri:path(),
    Request :: ecoap_message:coap_message(),
    Content :: ecoap_content:ecoap_content(),
    Error :: ecoap_message:error_code(),
    Reason :: reason().
-optional_callbacks([coap_fetch/4]). 

% POST handler
-callback coap_post(EpID, Prefix, Suffix, Request) -> 
    {ok, Code, Content} | {error, Error} | {error, Error, Reason} when
    EpID :: ecoap_endpoint:ecoap_endpoint_id(),
    Prefix :: ecoap_uri:path(),
    Suffix :: ecoap_uri:path(),
    Request :: ecoap_message:coap_message(),
    Code :: ecoap_message:success_code(),
    Content :: ecoap_content:ecoap_content(),
    Error :: ecoap_message:error_code(),
    Reason :: reason().
-optional_callbacks([coap_post/4]). 

% PUT handler
-callback coap_put(EpID, Prefix, Suffix, Request) -> 
    ok | {ok, Content} | {error, Error} | {error, Error, Reason} when
    EpID :: ecoap_endpoint:ecoap_endpoint_id(),
    Prefix :: ecoap_uri:path(),
    Suffix :: ecoap_uri:path(),
    Request :: ecoap_message:coap_message(),
    Content :: ecoap_content:ecoap_content(),
    Error :: ecoap_message:error_code(),
    Reason :: reason().
-optional_callbacks([coap_put/4]).  

% PATCH handler
-callback coap_patch(EpID, Prefix, Suffix, Request) -> 
    ok | {ok, Content} | {error, Error} | {error, Error, Reason} when
    EpID :: ecoap_endpoint:ecoap_endpoint_id(),
    Prefix :: ecoap_uri:path(),
    Suffix :: ecoap_uri:path(),
    Request :: ecoap_message:coap_message(),
    Content :: ecoap_content:ecoap_content(),
    Error :: ecoap_message:error_code(),
    Reason :: reason().
-optional_callbacks([coap_patch/4]).

% iPATCH handler
-callback coap_ipatch(EpID, Prefix, Suffix, Request) -> 
    ok | {ok, Content} | {error, Error} | {error, Error, Reason} when
    EpID :: ecoap_endpoint:ecoap_endpoint_id(),
    Prefix :: ecoap_uri:path(),
    Suffix :: ecoap_uri:path(),
    Request :: ecoap_message:coap_message(),
    Content :: ecoap_content:ecoap_content(),
    Error :: ecoap_message:error_code(),
    Reason :: reason().
-optional_callbacks([coap_ipatch/4]).  

% DELETE handler
-callback coap_delete(EpID, Prefix, Suffix, Request) -> 
    ok | {ok, Content} | {error, Error} | {error, Error, Reason} when
    EpID :: ecoap_endpoint:ecoap_endpoint_id(),
    Prefix :: ecoap_uri:path(),
    Suffix :: ecoap_uri:path(),
    Request :: ecoap_message:coap_message(),
    Content :: ecoap_content:ecoap_content(),
    Error :: ecoap_message:error_code(),
    Reason :: reason().
-optional_callbacks([coap_delete/4]).   

% observe request handler
-callback coap_observe(EpID, Prefix, Suffix, Request) -> 
    {ok, ObState} | {error, Error} | {error, Error, Reason} when
    EpID :: ecoap_endpoint:ecoap_endpoint_id(),
    Prefix :: ecoap_uri:path(),
    Suffix :: ecoap_uri:path(),
    Request :: ecoap_message:coap_message(),
    ObState :: observe_state(),
    Error :: ecoap_message:error_code(),
    Reason :: reason().
-optional_callbacks([coap_observe/4]).  

% cancellation request handler
-callback coap_unobserve(ObState) -> 
    ok when
    ObState :: observe_state().
-optional_callbacks([coap_unobserve/1]).    

% handler for messages sent to the coap_handler process
% could be used to generate notifications
% notifications sent by calling ecoap_handler:notify/2 arrives as {coap_notify, Msg} 
% where one can check Content-Format of notifications according to original observe request ObsReq, send the msg or return {error, 'NotAcceptable'}
% the function can also be used to generate tags which correlate outgoing CON notifications with incoming ACKs
-callback handle_info(Info, ObsReq, ObState) -> 
    {notify, Content, NewObState} |
    {notify, {error, Error}, NewObState} |
    {notify, Ref, Content, NewObState} | 
    {notify, Ref, {error, Error}, NewObState} |
    {noreply, NewObState} | 
    {stop, NewObState} when
    Info :: {coap_notify, term()} | term(),
    ObsReq :: ecoap_message:coap_message(),
    ObState :: observe_state(),
    Ref :: observe_ref(),
    Content :: ecoap_content:ecoap_content(),
    Error :: ecoap_message:error_code(),
    NewObState :: observe_state().
-optional_callbacks([handle_info/3]).   

% response to notifications
-callback coap_ack(Ref, ObState) -> 
    {ok, NewObState} when
    Ref :: observe_ref(),
    ObState :: observe_state(),
    NewObState :: observe_state().
-optional_callbacks([coap_ack/2]).  

%% API.

-spec start_link(ecoap_endpoint:handler_id(), ecoap_config:handler_config()) -> {ok, pid()} | {error, term()}.
start_link(ID, HandlerConfig) ->
    gen_server:start_link(?MODULE, [ID, HandlerConfig], []).

-spec close(pid()) -> ok.
close(Pid) ->
    gen_server:cast(Pid, shutdown).

-spec notify(ecoap_uri:path(), term()) -> ok.
notify(Uri, Info) ->
    List = spg:get_members({coap_observer, Uri}),
    lists:foreach(fun(Pid) -> Pid ! {coap_notify, Info} end, List).
    % Maybe the following is better
    % List -> lists:foreach(fun(Pid) -> erlang:send(Pid, {coap_notify, Info}, [noconnect]) end, List)

%% gen_server.

init([ID={_, Uri, _}, HandlerConfig]) ->
    #{endpoint_pid:=EndpointPid, exchange_lifetime:=Timeout, max_body_size:=MaxBodySize, max_block_size:=MaxBlockSize} = HandlerConfig,
    State = #state{insegs={orddict:new(), undefined},
                    endpoint_pid=EndpointPid, 
                    cache_timeout=Timeout, 
                    max_body_size=MaxBodySize, 
                    max_block_size=MaxBlockSize,
                    % query=Query,
                    uri=Uri,
                    id=ID,
                    obseq=0},
    {ok, State}.

handle_call(_Request, _From, State) ->
    logger:log(error, "~p received unexpected call ~p in ~p~n", [self(), _Request, ?MODULE]),
    {noreply, State}.

handle_cast(shutdown, State=#state{observer=undefined}) ->
    {stop, normal, State};
handle_cast(shutdown, State=#state{module=Module, obstate=ObState}) ->
    % ok = coap_unobserve(Module, ObState),
    _ = invoke_callback(Module, coap_unobserve, 1, [ObState], ok),
    {stop, normal, cancel_observer(State)};
handle_cast(_Msg, State) ->
    logger:log(error, "~p received unexpected cast ~p in ~p~n", [self(), _Msg, ?MODULE]),
    {noreply, State}.

%% TODO:
% we can add another callback here which will be called before the request gets processed
% it can be used to invoke customized request handling logic
% question: do we need it?

% the first time the handler process recv request
handle_info({coap_request, EpID, EndpointPid, _Receiver=undefined, Request}, State=#state{prefix=undefined, suffix=undefined, uri=Uri}) ->
    % the receiver will be determined based on the URI
    case ecoap_registry:match_handler(Uri) of
        {{Prefix, Module}, Suffix} ->
            handle(EpID, Request, State#state{prefix=Prefix, suffix=Suffix, module=Module});
        undefined ->
            {ok, _} = ecoap_endpoint:send(EndpointPid,
                ecoap_request:response({error, 'NotFound'}, Request)),
            {stop, normal, State}
    end;
% following request sent to this handler process
handle_info({coap_request, EpID, _EndpointPid, _Receiver=undefined, Request}, State) ->
    handle(EpID, Request, State);
handle_info({coap_ack, _EpID, _EndpointPid, Ref}, State=#state{module=Module, obstate=ObState}) ->
    % {ok, ObState2} = coap_ack(Module, Ref, ObState),
    {ok, ObState2} = invoke_callback(Module, coap_ack, 2, [Ref, ObState], {ok, ObState}),
    {noreply, State#state{obstate=ObState2}};
% coap_error can be timeout or RST
handle_info({coap_error, _, _, _, _}, State=#state{observer=undefined}) ->
    % client is not in an observe relation
    % might be seen during the first block-wise transfer of a separate response
    {stop, normal, State};
handle_info({coap_error, _EpID, _EndpointPid, _Ref, _Error}, State=#state{module=Module, obstate=ObState}) ->
    % ok = coap_unobserve(Module, ObState),
    _ = invoke_callback(Module, coap_unobserve, 1, [ObState], ok),
    {stop, normal, cancel_observer(State)};
handle_info({timeout, TRef, cache_expired}, State=#state{observer=undefined, timer=TRef}) ->
    {stop, normal, State};
handle_info({timeout, TRef, cache_expired}, State=#state{timer=TRef}) ->
    % multi-block cache expired, but the observer is still active
    {noreply, State#state{last_response=undefined}};
handle_info(_Info, State=#state{observer=undefined}) ->
    % ignore unexpected notification
    logger:log(error, "~p received unexpected info ~p in ~p~n", [self(), _Info, ?MODULE]),
    {noreply, State};

% 1. handle_info succeeds, 
% calling coap_unobserve fails, which is caught, trigger send_server_error which calls cancel_observer and return error
% 2. handle_info fails or return bad value,
% which is caught, then trigger send_server_error, which calls cancel_observer and return error
% 3. client send unobserve request, call coap_unobserve, which fails, 
% trigger send_server_error, which calls cancel_observer and return error

% how to invoke cancel_observer/coap_unobserve only once?

% when will we call coap_unobserve?
% 1. client send unobserve request, we should cleanup, return response to GET request if no exception occurrs, otherwise return internal error
% 2. call shutdown of ecoap_handler, we should cleanup and not return anything to client(?)
% 3. received client rst on observe, we should cleanup and not return anything
% 4. handle_info returns {stop, ...}, we should cleanup and not return anything to client(?)
% 5. handle_info returns {error, ...}, we should cleanup return {error, ...} to client 

% 1 is included in normal processing chain and will be catched in cased of exception
% 2, 3 is not in the chain
% 4, 5 need more considering

%% TODO: 
%% how to safely invoke coap_unobserve and ensure only invoke once, no matter under sucess or failure

handle_info(Info, State=#state{module=Module, observer=Observer, obstate=ObState}) ->
    try case invoke_callback(Module, handle_info, 3, [Info, Observer, ObState], {noreply, ObState}) of
        {notify, Resource, ObState2} -> 
            handle_notify(undefined, Resource, ObState2, Observer, State);
        {notify, Ref, Resource, ObState2} ->
            handle_notify(Ref, Resource, ObState2, Observer, State);
        {noreply, ObState2} ->
            {noreply, State#state{obstate=ObState2}};
        {stop, ObState2} ->
            handle_notify(undefined, {error, 'ServiceUnavailable'}, ObState2, Observer, State)
    end catch C:R:S ->
        % send message directly without calling another user-defined callback (coap_unobserve) if this is a crash
        % because we do not want to be override by another possible crash
        send_server_error(Observer, State),
        error_terminate(C, R, S)
    end.

handle_notify(Ref, {error, Code}, ObState2, Observer, State) ->
    handle_notify(Ref, {error, Code, <<>>}, ObState2, Observer, State);
handle_notify(Ref, {error, Code, Reason}, ObState2, Observer, State) ->
    cancel_observe_and_send_response(Ref, Observer, {error, Code, Reason}, State#state{obstate=ObState2});
handle_notify(Ref, Content, ObState2, Observer, State) ->
    return_resource(Ref, Observer, {ok, 'Content'}, Content, State#state{obstate=ObState2}).

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Internal

%% Workflow

%% Check Block1 option 
%% (Continue Block1 transfer (upload), terminate if error otherwise assemble payload)
%% Check Block2 option
%% (Return designated block and wait for more request(s) until end when Block2 > 0)
%% Check preconditions
%% (Terminate if preconditions check failed)
%% Handle method
%% (Check Observe option if Method=GET)
%% (Handle Observe/Unobserve)
%% Return response

handle(EpID, Request, State=#state{id=ID, cache_timeout=TimeOut, endpoint_pid=EndpointPid}) ->
    Block1 = ecoap_message:get_option('Block1', Request),
    try assemble_payload(Request, Block1, State) of
        {'Continue', State2} ->
            ecoap_endpoint:register_handler(EndpointPid, ID, self()),
            {ok, _} = ecoap_endpoint:send_response(EndpointPid, undefined,
                ecoap_message:set_option('Block1', Block1,
                    ecoap_request:response({ok, 'Continue'}, Request))),
            set_timeout(TimeOut, State2);
        {ok, Payload, State2} ->
            process_request(EpID, Request#coap_message{payload=Payload}, State2);
        {error, Code} ->
            return_response(Request, {error, Code}, State)
    catch throw:{error, Code} ->
        return_response(Request, {error, Code}, State)
    end.

assemble_payload(#coap_message{payload=Payload}, undefined, State) ->
    {ok, Payload, State};
assemble_payload(Request, Block1={Num, _, _}, State=#state{insegs={Segs, CurrentFormat}}) ->
    Format = ecoap_message:get_option('Content-Format', Request),
    case {Num, orddict:is_empty(Segs)} of
        {Num, true} when Num > 0 -> 
            % A server can reject a Block1 transfer with RequestEntityIncomplete when NUM != 0
            {error, 'RequestEntityIncomplete'};
        {0, false} ->
            % in case block1 transfer overlap, we always use the newer one
            process_blocks(Request, Block1, State#state{insegs={orddict:new(), Format}});
        {_, _} ->
            case CurrentFormat of
                undefined -> 
                    process_blocks(Request, Block1, State#state{insegs={Segs, Format}});
                Format ->
                    process_blocks(Request, Block1, State);
                _ -> 
                    % A server can reject a Block1 transfer with RequestEntityIncomplete when 
                    % a different Content-Format is indicated than expected from the current state of the resource.
                    {error, 'RequestEntityIncomplete'}
            end
    end.

process_blocks(#coap_message{payload=Segment}, {Num, true, Size}, State=#state{insegs={Segs, Format}, max_body_size=MaxBodySize}) ->
    case byte_size(Segment) of
        Size when Num*Size < MaxBodySize -> {'Continue', State#state{insegs={orddict:store(Num, Segment, Segs), Format}}};
        Size -> {error, 'RequestEntityTooLarge'};
        _ -> {error, 'BadRequest'}
    end;
process_blocks(#coap_message{payload=Segment}, {_Num, false, _Size}, State=#state{insegs={Segs, _}}) ->
    Payload = orddict:fold(
        fun (Num1, Segment1, Acc) when Num1*byte_size(Segment1) == byte_size(Acc) ->
                <<Acc/binary, Segment1/binary>>;
            (_, _, _Acc) ->
                throw({error, 'RequestEntityIncomplete'})
        end, <<>>, Segs),
    {ok, <<Payload/binary, Segment/binary>>, State#state{insegs={orddict:new(), undefined}}}.

process_request(EpID, Request, State=#state{last_response={ok, Code, Content}}) ->
    case ecoap_message:get_option('Block2', Request) of
        {N, _, _} when N > 0 ->
            return_resource(undefined, Request, {ok, Code}, Content, State);
        _Else ->
            try_check_resource(EpID, Request, State)
    end;
process_request(EpID, Request, State) ->
    try_check_resource(EpID, Request, State).

try_check_resource(EpID, Request, State) ->
    try check_resource(EpID, Request, State)
    catch C:R:S ->
        send_server_error(Request, State),
        error_terminate(C, R, S)
    end.

check_resource(EpID, Request, State=#state{prefix=Prefix, suffix=Suffix, module=Module}) ->
    Result = case invoke_callback(Module, coap_get, 4, [EpID, Prefix, Suffix, Request], {error, 'MethodNotAllowed'}) of
        {ok, Content} -> Content;
        Other -> Other
    end,
    check_preconditions(EpID, Request, Result, State).

check_preconditions(EpID, Request, Content, State) ->
    case if_match(Request, Content) andalso if_none_match(Request, Content) of
        true ->
            handle_method(EpID, Request, Content, State);
        false ->
            return_response(Request, {error, 'PreconditionFailed'}, State)
    end.

if_match(Request, {error, _}) ->
    not ecoap_message:has_option('If-Match', Request);
if_match(Request, {error, _, _}) ->
    not ecoap_message:has_option('If-Match', Request);
if_match(Request, #ecoap_content{options=Options}) ->
    case ecoap_message:get_option('If-Match', Request, []) of
        % empty string matches any existing representation
        [] -> true;
        % match exact resources
        List -> lists:member(get_etag(Options), List)
    end.

if_none_match(_Request, {error, _}) ->
    true;
if_none_match(_Request, {error, _, _}) ->
    true;
if_none_match(Request, _Content) ->
    not ecoap_message:has_option('If-None-Match', Request).

handle_method(_EpID, Request=#coap_message{code=Code}, {error, Error}, State) when Code =:= 'GET'; Code =:= 'FETCH' ->
    return_response(Request, {error, Error}, State);
handle_method(_EpID, Request=#coap_message{code=Code}, {error, Error, Reason}, State) when Code =:= 'GET'; Code =:= 'FETCH' ->
    return_response(undefined, Request, {error, Error}, Reason, State);
handle_method(EpID,  Request=#coap_message{code='GET'}, Content, State) ->
    check_observe(EpID, Request, Content, State);
handle_method(EpID, Request=#coap_message{code='FETCH'}, _Content, State) ->    
    handle_fetch(EpID, Request, State);
handle_method(EpID, Request=#coap_message{code='POST'}, _Content, State) ->
    handle_post(EpID, Request, State);
handle_method(EpID, Request=#coap_message{code='PUT'}, Content, State) ->
    handle_put(EpID, Request, Content, State);
handle_method(EpID, Request=#coap_message{code='DELETE'}, _Content, State) ->
    handle_delete(EpID, Request, State);
handle_method(EpID, Request=#coap_message{code='PATCH'}, Content, State) ->
    handle_patch(EpID, Request, Content, State);
handle_method(EpID, Request=#coap_message{code='iPATCH'}, Content, State) ->
    handle_ipatch(EpID, Request, Content, State);
handle_method(_EpID, Request, _Content, State) ->
    return_response(Request, {error, 'MethodNotAllowed'}, State).

handle_fetch(EpID, Request, State=#state{module=Module, prefix=Prefix, suffix=Suffix}) ->
    case invoke_callback(Module, coap_fetch, 4, [EpID, Prefix, Suffix, Request], {error, 'MethodNotAllowed'}) of
        {ok, Content2} ->
            check_observe(EpID, Request, Content2, State);
        {error, Error} ->
            return_response(Request, {error, Error}, State);
        {error, Error, Reason} ->
            return_response(undefined, Request, {error, Error}, Reason, State)
    end.

check_observe(EpID, Request, Content, State) ->
    case ecoap_message:get_option('Observe', Request) of
        0 ->
            handle_observe(EpID, Request, Content, State);
        1 ->
            handle_unobserve(EpID, Request, Content, State);
        undefined ->
            return_resource(Request, Content, State);
        _Else ->
            return_response(Request, {error, 'BadOption'}, State)
    end.

% TODO: 
% when there is a cluster of servers, it is likely a load balancer that does not use sticky mode
% dispatches observe requests from a single client to different server instances, which creates duplicate 
% observer handler instances
% This can be avoided using another type of group which looks like {EpID, Uri} consisting of only one member 
% Let the first started handler join and followers can detect duplicate by checking if the group is empty or not
% PROBLEM: what should the follower do to resolve the duplication? 
% forward the request to the one it found and terminate
% or kill the one it found and serve the request by itself? 
handle_observe(EpID, Request, Content, 
        State=#state{endpoint_pid=EndpointPid, id=ID, prefix=Prefix, suffix=Suffix, uri=Uri, module=Module, observer=undefined}) ->
    % the first observe request from this user to this resource
    case invoke_callback(Module, coap_observe, 4, [EpID, Prefix, Suffix, Request], {error, 'MethodNotAllowed'}) of
        {ok, ObState} ->
            ecoap_endpoint:register_handler(EndpointPid, ID, self()),
            ok = spg:join({coap_observer, Uri}, self()),
            return_resource(Request, Content, State#state{observer=Request, obstate=ObState});
        {error, 'MethodNotAllowed'} ->
            % observe is not supported, fallback to standard get
            return_resource(Request, Content, State#state{observer=undefined});
        {error, Error} ->
            return_response(Request, {error, Error}, State);
        {error, Error, Reason} ->
            return_response(undefined, Request, {error, Error}, Reason, State)
    end;
handle_observe(_EpID, Request, Content, State) ->
    % subsequent observe request from the same user
    return_resource(Request, Content, State#state{observer=Request}).

handle_unobserve(_EpID, Request=#coap_message{token=Token}, Content, State=#state{observer=#coap_message{token=Token}}) ->
    cancel_observe_and_send_response(Request, Content, State);
handle_unobserve(_EpID, Request, Content, State) ->
    return_resource(Request, Content, State).

cancel_observe_and_send_response(Request, Response, State) ->
    cancel_observe_and_send_response(undefined, Request, Response, State).

cancel_observe_and_send_response(Ref, Request, Response, State=#state{module=Module, obstate=ObState}) ->
    _ = invoke_callback(Module, coap_unobserve, 1, [ObState], ok),
    State2 = cancel_observer(State),
    case Response of
        {error, Code, Reason} ->
            return_response(Ref, Request, {error, Code}, Reason, State2);
        #ecoap_content{} ->
            return_resource(Ref, Request, {ok, 'Content'}, Response, State2)
    end.

cancel_observer(State=#state{uri=Uri}) ->
    ok = spg:leave({coap_observer, Uri}, self()),
    State#state{observer=undefined, obstate=undefined}.

handle_post(EpID, Request, State=#state{prefix=Prefix, suffix=Suffix, module=Module}) ->
    case invoke_callback(Module, coap_post, 4, [EpID, Prefix, Suffix, Request], {error, 'MethodNotAllowed'}) of
        {ok, Code, Content} ->
            return_resource(undefined, Request, {ok, Code}, Content, State);
        {error, Error} ->
            return_response(Request, {error, Error}, State);
        {error, Error, Reason} ->
            return_response(undefined, Request, {error, Error}, Reason, State)
    end.

handle_put(EpID, Request, Content, State=#state{prefix=Prefix, suffix=Suffix, module=Module}) ->
    case invoke_callback(Module, coap_put, 4, [EpID, Prefix, Suffix, Request], {error, 'MethodNotAllowed'}) of
        ok ->
            return_response(Request, created_or_changed(Content), State);
        {ok, Content} ->
            return_resource(undefined, Request, created_or_changed(Content), Content, State);
        {error, Error} ->
            return_response(Request, {error, Error}, State);
        {error, Error, Reason} ->
            return_response(undefined, Request, {error, Error}, Reason, State)
    end.

handle_patch(EpID, Request, Content, State=#state{prefix=Prefix, suffix=Suffix, module=Module}) ->
    case invoke_callback(Module, coap_patch, 4, [EpID, Prefix, Suffix, Request], {error, 'MethodNotAllowed'}) of
        ok ->
            return_response(Request, created_or_changed(Content), State);
        {ok, Content} ->
            return_resource(undefined, Request, created_or_changed(Content), Content, State);
        {error, Error} ->
            return_response(Request, {error, Error}, State);
        {error, Error, Reason} ->
            return_response(undefined, Request, {error, Error}, Reason, State)
    end.

handle_ipatch(EpID, Request, Content, State=#state{prefix=Prefix, suffix=Suffix, module=Module}) ->
    case invoke_callback(Module, coap_ipatch, 4, [EpID, Prefix, Suffix, Request], {error, 'MethodNotAllowed'}) of
        ok ->
            return_response(Request, created_or_changed(Content), State);
        {ok, Content} ->
            return_resource(undefined, Request, created_or_changed(Content), Content, State);
        {error, Error} ->
            return_response(Request, {error, Error}, State);
        {error, Error, Reason} ->
            return_response(undefined, Request, {error, Error}, Reason, State)
    end.

created_or_changed({error, 'NotFound'}) ->
    {ok, 'Created'};
created_or_changed(_Content) ->
    {ok, 'Changed'}.

handle_delete(EpID, Request, State=#state{prefix=Prefix, suffix=Suffix, module=Module}) ->
    case invoke_callback(Module, coap_delete, 4, [EpID, Prefix, Suffix, Request], {error, 'MethodNotAllowed'}) of
        ok ->
            return_response(Request, {ok, 'Deleted'}, State);
        {ok, Content} ->
            return_resource(undefined, Request, created_or_changed(Content), Content, State);
        {error, Error} ->
            return_response(Request, {error, Error}, State);
        {error, Error, Reason} ->
            return_response(undefined, Request, {error, Error}, Reason, State)
    end.

return_resource(Request, Content, State) ->
    return_resource(undefined, Request, {ok, 'Content'}, Content, State).

return_resource(Ref, Request, {ok, Code}, Content=#ecoap_content{payload=Payload, options=Options}, State=#state{max_block_size=MaxBlockSize}) ->
    ETag = get_etag(Options),
    Response = case lists:member(ETag, ecoap_message:get_option('ETag', Request, [])) of
            true ->
                ecoap_message:set_option('ETag', [ETag],
                    ecoap_request:response({ok, 'Valid'}, Request));
            false ->
                ecoap_request:set_payload(Payload, ecoap_message:get_option('Block2', Request), 
                    ecoap_message:merge_options(Options, ecoap_request:response({ok, Code}, Request)), MaxBlockSize)
    end,
    send_observable(Ref, Request, Response, State#state{last_response={ok, Code, Content}}). 

send_observable(Ref, _Request, Response, State=#state{observer=undefined}) ->
    send_response(Ref, Response, State);
send_observable(Ref, Request=#coap_message{token=Token}, Response, State=#state{observer=Observer, obseq=Seq}) ->
    case {ecoap_message:get_option('Observe', Request), Observer} of
        % when requested observe and is observing, return the sequence number
        {0, #coap_message{token=Token}} ->
            send_response(Ref, ecoap_message:set_option('Observe', Seq, Response), State#state{obseq=next_seq(Seq)});
        _Else ->
            send_response(Ref, Response, State)
    end.       

return_response(Request, Code, State) ->
    return_response(undefined, Request, Code, <<>>, State).

return_response(Ref, Request, Code, Reason, State) ->
    send_response(Ref, ecoap_request:response(Code, Reason, Request), State#state{last_response=Code}).

send_response(Ref, Response, State=#state{endpoint_pid=EndpointPid, cache_timeout=TimeOut, observer=Observer, id=ID}) ->
    {ok, _} = ecoap_endpoint:send_response(EndpointPid, Ref, Response),
    case ecoap_message:get_option('Block2', Response) of
        {_, true, _} ->
            % client is expected to ask for more blocks
            ecoap_endpoint:register_handler(EndpointPid, ID, self()),
            set_timeout(TimeOut, State);
        _ ->
            case Observer of
                undefined ->
                    % no further communication concerning this request
                    {stop, normal, State};
                #coap_message{} ->
                    % notifications will follow
                    {noreply, State}
            end
    end.

set_timeout(Timeout, State=#state{timer=undefined}) ->
    set_timeout0(State, Timeout);
set_timeout(Timeout, State=#state{timer=Timer}) ->
    _ = ecoap_timer:cancel_timer(Timer),
    set_timeout0(State, Timeout).

set_timeout0(State, Timeout) ->
    Timer = ecoap_timer:start_standard(Timeout, self(), cache_expired),
    {noreply, State#state{timer=Timer}}.

next_seq(Seq) when Seq < 16#0FFF -> Seq + 1;
next_seq(_) -> 0.

get_etag(Options) ->
    case ecoap_message:get_option('ETag', Options) of
        [ETag] -> ETag;
        undefined -> undefined
    end.

% coap_get(Module, EpID, Prefix, Suffix, Request) ->
%     case erlang:function_exported(Module, coap_get, 4) of
%         true -> Module:coap_get(EpID, Prefix, Suffix, Request);
%         false -> {error, 'MethodNotAllowed'}
%     end.

% coap_fetch(Module, EpID, Prefix, Suffix, Request) ->
%     case erlang:function_exported(Module, coap_fetch, 4) of
%         true -> Module:coap_fetch(EpID, Prefix, Suffix, Request);
%         false -> {error, 'MethodNotAllowed'}
%     end.

% coap_post(Module, EpID, Prefix, Suffix, Request) ->
%     case erlang:function_exported(Module, coap_post, 4) of
%         true -> Module:coap_post(EpID, Prefix, Suffix, Request);
%         false -> {error, 'MethodNotAllowed'}
%     end.

% coap_put(Module, EpID, Prefix, Suffix, Request) ->
%     case erlang:function_exported(Module, coap_put, 4) of
%         true -> Module:coap_put(EpID, Prefix, Suffix, Request);
%         false -> {error, 'MethodNotAllowed'}
%     end.

% coap_patch(Module, EpID, Prefix, Suffix, Request) ->
%     case erlang:function_exported(Module, coap_patch, 4) of
%         true -> Module:coap_patch(EpID, Prefix, Suffix, Request);
%         false -> {error, 'MethodNotAllowed'}
%     end.

% coap_ipatch(Module, EpID, Prefix, Suffix, Request) ->
%     case erlang:function_exported(Module, coap_ipatch, 4) of
%         true -> Module:coap_ipatch(EpID, Prefix, Suffix, Request);
%         false -> {error, 'MethodNotAllowed'}
%     end.

% coap_delete(Module, EpID, Prefix, Suffix, Request) ->
%     case erlang:function_exported(Module, coap_delete, 4) of
%         true -> Module:coap_delete(EpID, Prefix, Suffix, Request);
%         false -> {error, 'MethodNotAllowed'}
%     end.

% coap_observe(Module, EpID, Prefix, Suffix, Request) ->
%     case erlang:function_exported(Module, coap_observe, 4) of
%         true -> Module:coap_observe(EpID, Prefix, Suffix, Request);
%         false -> {error, 'MethodNotAllowed'}
%     end.

% coap_unobserve(Module, ObState) ->
%     case erlang:function_exported(Module, coap_unobserve, 1) of
%         true -> Module:coap_unobserve(ObState);
%         false -> ok
%     end.

% handle_info(Module, Info, ObsReq, ObState) ->
%     case erlang:function_exported(Module, handle_info, 3) of
%         true -> Module:handle_info(Info, ObsReq, ObState);
%         false ->
%             case Info of
%                 {coap_notify, Msg} -> {notify, Msg, ObState};
%                 _ -> {noreply, ObState}
%             end
%     end.

% coap_ack(Module, Ref, ObState) ->
%     case erlang:function_exported(Module, coap_ack, 2) of
%         true -> Module:coap_ack(Ref, ObState);
%         false -> {ok, ObState}
%     end.

invoke_callback(Module, Function, Arity, Args, Default) ->
    case erlang:function_exported(Module, Function, Arity) of
        true -> erlang:apply(Module, Function, Args);
        false -> Default
    end.

send_server_error(Request, State) ->
    send_server_error(undefined, Request, State).

send_server_error(Ref, Request, #state{endpoint_pid=EndpointPid}) ->
    {ok, _} = ecoap_endpoint:send_response(EndpointPid, Ref, ecoap_request:response({error, 'InternalServerError'}, <<>>, Request)),
    ok.

error_terminate(Class, {case_clause, BadReply}, Stacktrace) ->
    erlang:raise(Class, {bad_return_value, BadReply}, Stacktrace);
error_terminate(Class, {badmatch, BadReply}, Stacktrace) ->
    erlang:raise(Class, {bad_return_value, BadReply}, Stacktrace);
error_terminate(Class, Reason, Stacktrace) ->
    erlang:raise(Class, Reason, Stacktrace).
