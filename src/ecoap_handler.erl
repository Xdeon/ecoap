-module(ecoap_handler).
-behaviour(gen_server).

-export([start_link/2, close/1, notify/2, handler_id/1]).

%% gen_server.
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-include("coap_message.hrl").
-include("coap_content.hrl").

-record(state, {
    config = undefined :: ecoap_default:config(),
    id = undefined :: handler_id(),
    module = undefined :: module(), 
    insegs = undefined :: {orddict:orddict(), undefined | binary() | non_neg_integer()}, 
    last_response = undefined :: last_response(),
    observer = undefined :: undefined | coap_message:coap_message(), 
    obseq = undefined :: non_neg_integer(), 
    obstate = undefined :: term(), 
    timer = undefined :: undefined | reference(),
    uri = undefined :: uri(),
    prefix = undefined :: undefined | uri(), 
    suffix = undefined :: undefined | uri(),
    query = undefined :: query()}).

-type method() :: atom().
-type uri() :: ecoap_uri:path().
-type query() :: ecoap_uri:query().
-type reason() :: binary().
-type observe_ref() :: term().
-type observe_state() :: term().
-type handler_id() :: {{method(), uri(), query()}, coap_message:token() | undefined}.

-type last_response() ::
    undefined |
    {ok, coap_message:success_code(), coap_content:coap_content()} |
    coap_message:coap_success() | 
    coap_message:coap_error().

-export_type([uri/0, query/0, reason/0, handler_id/0]).

% called when a client asks for .well-known/core resources
-callback coap_discover(Prefix) -> [Uri] when
    Prefix :: uri(),
    Uri :: core_link:coap_uri().
-optional_callbacks([coap_discover/1]). 

% GET handler
-callback coap_get(EpID, Prefix, Suffix, Query, Request) -> 
    {ok, Content} | {error, Error} | {error, Error, Reason} when
    EpID :: ecoap_endpoint:ecoap_endpoint_id(),
    Prefix :: uri(),
    Suffix :: uri(),
    Query :: 'query'(),
    Request :: coap_message:coap_message(),
    Content :: coap_content:coap_content(),
    Error :: coap_message:error_code(),
    Reason :: reason().
-optional_callbacks([coap_get/5]). 

% POST handler
-callback coap_post(EpID, Prefix, Suffix, Request) -> 
    {ok, Code, Content} | {error, Error} | {error, Error, Reason} when
    EpID :: ecoap_endpoint:ecoap_endpoint_id(),
    Prefix :: uri(),
    Suffix :: uri(),
    Request :: coap_message:coap_message(),
    Code :: coap_message:success_code(),
    Content :: coap_content:coap_content(),
    Error :: coap_message:error_code(),
    Reason :: reason().
-optional_callbacks([coap_post/4]). 

% PUT handler
-callback coap_put(EpID, Prefix, Suffix, Request) -> ok | {error, Error} | {error, Error, Reason} when
    EpID :: ecoap_endpoint:ecoap_endpoint_id(),
    Prefix :: uri(),
    Suffix :: uri(),
    Request :: coap_message:coap_message(),
    Error :: coap_message:error_code(),
    Reason :: reason().
-optional_callbacks([coap_put/4]).  

% DELETE handler
-callback coap_delete(EpID, Prefix, Suffix, Request) -> ok | {error, Error} | {error, Error, Reason} when
    EpID :: ecoap_endpoint:ecoap_endpoint_id(),
    Prefix :: uri(),
    Suffix :: uri(),
    Request :: coap_message:coap_message(),
    Error :: coap_message:error_code(),
    Reason :: reason().
-optional_callbacks([coap_delete/4]).   

% observe request handler
-callback coap_observe(EpID, Prefix, Suffix, Request) -> {ok, ObState} | {error, Error} | {error, Error, Reason} when
    EpID :: ecoap_endpoint:ecoap_endpoint_id(),
    Prefix :: uri(),
    Suffix :: uri(),
    Request :: coap_message:coap_message(),
    ObState :: observe_state(),
    Error :: coap_message:error_code(),
    Reason :: reason().
-optional_callbacks([coap_observe/4]).  

% cancellation request handler
-callback coap_unobserve(ObState) -> ok when
    ObState :: observe_state().
-optional_callbacks([coap_unobserve/1]).    

% handler for messages sent to the coap_handler process
% could be used to generate notifications
% notifications sent by calling ecoap_handler:notify/2 arrives as {coap_notify, Msg} 
% where on can check Content-Format of notifications according to original observe request ObsReq, send the msg or return {error, 'NotAcceptable'}
% the function can also be used to generate tags which correlate outgoing CON notifications with incoming ACKs
-callback handle_info(Info, ObsReq, ObState) -> 
    {notify, Content, NewObState} |
    {notify, {error, Error}, NewObState} |
    {notify, Ref, Content, NewObState} | 
    {notify, Ref, {error, Error}, NewObState} |
    {noreply, NewObState} | 
    {stop, NewObState} when
    Info :: {coap_notify, term()} | term(),
    ObsReq :: coap_message:coap_message(),
    ObState :: observe_state(),
    Ref :: observe_ref(),
    Content :: coap_content:coap_content(),
    Error :: coap_message:error_code(),
    NewObState :: observe_state().
-optional_callbacks([handle_info/3]).   

% response to notifications
-callback coap_ack(Ref, ObState) -> {ok, NewObState} when
    Ref :: observe_ref(),
    ObState :: observe_state(),
    NewObState :: observe_state().
-optional_callbacks([coap_ack/2]).  

%% API.

-spec start_link(handler_id(), ecoap_default:config()) -> {ok, pid()} | {error, term()}.
start_link(ID, Config) ->
    gen_server:start_link(?MODULE, [ID, Config], []).


-spec close(pid()) -> ok.
close(Pid) ->
    gen_server:cast(Pid, shutdown).


-spec notify(uri(), term()) -> ok.
notify(Uri, Info) ->
    case pg2:get_members({coap_observer, Uri}) of
        {error, _} -> ok;
        List -> lists:foreach(fun(Pid) -> Pid ! {coap_notify, Info} end, List)
    end.


-spec handler_id(coap_message:coap_message()) -> handler_id().
handler_id(Message=#coap_message{code=Method, token=Token}) ->
    Uri = coap_message:get_option('Uri-Path', Message, []),
    Query = coap_message:get_option('Uri-Query', Message, []),
    case coap_message:get_option('Observe', Message) of
        undefined -> {{Method, Uri, Query}, undefined};
        _ -> {{Method, Uri, Query}, Token}
    end.


%% gen_server.

init([ID={{_, Uri, Query}, _}, Config=#{endpoint_pid:=EndpointPid}]) ->
    ecoap_endpoint:monitor_handler(EndpointPid, self()),
    {ok, #state{config=Config, id=ID, uri=Uri, query=Query, insegs={orddict:new(), undefined}, obseq=0}}.


handle_call(_Request, _From, State) ->
    error_logger:error_msg("unexpected call ~p received by ~p as ~p~n", [_Request, self(), ?MODULE]),
    {noreply, State}.


handle_cast(shutdown, State=#state{observer=undefined}) ->
    {stop, normal, State};

handle_cast(shutdown, State) ->
    try_cancel_observe_and_terminate(State);

handle_cast(_Msg, State) ->
    error_logger:error_msg("unexpected cast ~p received by ~p as ~p~n", [_Msg, self(), ?MODULE]),
    {noreply, State}.

% TODO:
% we can add another callback here which will be called before the request gets processed
% it can be used to invoke customized request handling logic
% question: do we need it?

% the first time the handler process recv request
handle_info({coap_request, EpID, EndpointPid, _Receiver=undefined, Request}, State=#state{prefix=undefined, suffix=undefined, uri=Uri}) ->
    % the receiver will be determined based on the URI
    case ecoap_registry:match_handler(Uri) of
        {{Prefix, Module}, Suffix} ->
            % io:fwrite("Prefix:~p Uri:~p~n", [Prefix, Uri]),
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
    try case coap_ack(Module, Ref, ObState) of
        {ok, ObState2} -> 
            {noreply, State#state{obstate=ObState2}}
    end catch C:R:S -> 
        error_terminate(C, R, S)
    end;

handle_info({coap_error, _EpID, _EndpointPid, _Ref, _Error}, State) ->
    try_cancel_observe_and_terminate(State);

handle_info({timeout, TRef, cache_expired}, State=#state{observer=undefined, timer=TRef}) ->
    {stop, normal, State};

handle_info({timeout, TRef, cache_expired}, State=#state{timer=TRef}) ->
    % multi-block cache expired, but the observer is still active
    {noreply, State#state{last_response=undefined}};

handle_info(_Info, State=#state{observer=undefined}) ->
    % ignore unexpected notification
    {noreply, State};

handle_info(Info, State=#state{module=Module, observer=Observer, obstate=ObState}) ->
    try case handle_info(Module, Info, Observer, ObState) of
        {notify, Msg, ObState2} -> 
            handle_notify([], Msg, ObState2, Observer, State);
        {notify, Ref, Msg, ObState2} ->
            handle_notify(Ref, Msg, ObState2, Observer, State);
        {noreply, ObState2} ->
            {noreply, State#state{obstate=ObState2}};
        {stop, ObState2} ->
            handle_notify([], {error, 'ServiceUnavailable'}, ObState2, Observer, State)
    end catch C:R:S ->
        % send message directly without calling another user-defined callback (coap_unobserve) if this is a crash
        % because we do not want to be override by another possible crash
        send_server_error(Observer, State),
        error_terminate(C, R, S)
    end.


handle_notify(Ref, {error, Code}, ObState2, Observer, State) ->
    try_cancel_observe_and_send_response(Ref, Observer, {error, Code}, State#state{obstate=ObState2});

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

handle(EpID, Request, State=#state{id=ID, config=#{exchange_lifetime:=TimeOut, endpoint_pid:=EndpointPid}}) ->
    Block1 = coap_message:get_option('Block1', Request),
    case catch assemble_payload(Request, Block1, State) of
        {error, Code} ->
            return_response(Request, {error, Code}, State);
        {'Continue', State2} ->
            % io:format("Has Block1~n"),
            ecoap_endpoint:register_handler(EndpointPid, ID, self()),
            {ok, _} = ecoap_endpoint:send_response(EndpointPid, [],
                coap_message:set_option('Block1', Block1,
                    ecoap_request:response({ok, 'Continue'}, Request))),
            set_timeout(TimeOut, State2);
        {ok, Payload, State2} ->
            process_request(EpID, Request#coap_message{payload=Payload}, State2)
    end.


assemble_payload(#coap_message{payload=Payload}, undefined, State) ->
    {ok, Payload, State};

assemble_payload(Request, Block1={Num, _, _}, State=#state{insegs={Segs, CurrentFormat}}) ->
    Format = coap_message:get_option('Content-Format', Request),
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


process_blocks(#coap_message{payload=Segment}, {Num, true, Size}, State=#state{insegs={Segs, Format}, config=#{max_body_size:=MaxSize}}) ->
    case byte_size(Segment) of
        Size when Num*Size < MaxSize -> {'Continue', State#state{insegs={orddict:store(Num, Segment, Segs), Format}}};
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
    case coap_message:get_option('Block2', Request) of
        {N, _, _} when N > 0 ->
            return_resource([], Request, {ok, Code}, Content, State);
        _Else ->
            check_resource(EpID, Request, State)
    end;

process_request(EpID, Request, State) ->
    check_resource(EpID, Request, State).


check_resource(EpID, Request, State=#state{prefix=Prefix, suffix=Suffix, query=Query, module=Module}) ->
    try case coap_get(Module, EpID, Prefix, Suffix, Query, Request) of
        {ok, Content} ->
            check_preconditions(EpID, Request, Content, State);
        {error, 'NotFound'} = Result ->
            check_preconditions(EpID, Request, Result, State);
        {error, Code} ->
            return_response(Request, {error, Code}, State);
        {error, Code, Reason} ->
            return_response([], Request, {error, Code}, Reason, State)
    end catch C:R:S ->
        send_server_error(Request, State),
        error_terminate(C, R, S)
    end.


check_preconditions(EpID, Request, Content, State) ->
    case if_match(Request, Content) andalso if_none_match(Request, Content) of
        true ->
            handle_method(EpID, Request, Content, State);
        false ->
            return_response(Request, {error, 'PreconditionFailed'}, State)
    end.


if_match(Request, {error, 'NotFound'}) ->
    not coap_message:has_option('If-Match', Request);

if_match(Request, #coap_content{options=Options}) ->
    case coap_message:get_option('If-Match', Request, []) of
        % empty string matches any existing representation
        [] -> true;
        % match exact resources
        List -> lists:member(get_etag(Options), List)
    end.


if_none_match(_Request, {error, _}) ->
    true;

if_none_match(Request, _Content) ->
    not coap_message:has_option('If-None-Match', Request).


handle_method(_EpID, Request=#coap_message{code='GET'}, {error, Code}, State) ->
    return_response(Request, {error, Code}, State);

handle_method(EpID, Request=#coap_message{code='GET'}, Content, State) ->
    case coap_message:get_option('Observe', Request) of
        0 ->
            handle_observe(EpID, Request, Content, State);
        1 ->
            handle_unobserve(EpID, Request, Content, State);
        undefined ->
            return_resource(Request, Content, State);
        _Else ->
            return_response(Request, {error, 'BadOption'}, State)
    end;

handle_method(EpID, Request=#coap_message{code='POST'}, _Content, State) ->
    handle_post(EpID, Request, State);

handle_method(EpID, Request=#coap_message{code='PUT'}, Content, State) ->
    handle_put(EpID, Request, Content, State);

handle_method(EpID, Request=#coap_message{code='DELETE'}, _Content, State) ->
    handle_delete(EpID, Request, State);

handle_method(_EpID, Request, _Content, State) ->
    return_response(Request, {error, 'MethodNotAllowed'}, State).


handle_observe(EpID, Request, Content, 
        State=#state{config=#{endpoint_pid:=EndpointPid}, id=ID, prefix=Prefix, suffix=Suffix, uri=Uri, module=Module, observer=undefined}) ->
    % the first observe request from this user to this resource
    try case coap_observe(Module, EpID, Prefix, Suffix, Request) of
        {ok, ObState} ->
            ecoap_endpoint:register_handler(EndpointPid, ID, self()),
            pg2:create({coap_observer, Uri}),
            ok = pg2:join({coap_observer, Uri}, self()),
            return_resource(Request, Content, State#state{observer=Request, obstate=ObState});
        {error, 'MethodNotAllowed'} ->
            % observe is not supported, fallback to standard get
            return_resource(Request, Content, State#state{observer=undefined});
        {error, Error} ->
            return_response(Request, {error, Error}, State);
        {error, Error, Reason} ->
            return_response([], Request, {error, Error}, Reason, State)
    end catch C:R:S->
        send_server_error(Request, State),
        error_terminate(C, R, S)
    end;

handle_observe(_EpID, Request, Content, State) ->
    % subsequent observe request from the same user
    return_resource(Request, Content, State#state{observer=Request}).


handle_unobserve(_EpID, Request=#coap_message{token=Token}, Content, State=#state{observer=#coap_message{token=Token}}) ->
    try_cancel_observe_and_send_response(Request, Content, State);

handle_unobserve(_EpID, Request, Content, State) ->
    return_resource(Request, Content, State).


try_cancel_observe_and_terminate(State=#state{module=Module, obstate=ObState}) ->
    try case coap_unobserve(Module, ObState) of
        ok -> {stop, normal, cancel_observer(State)}
    end catch C:R:S -> 
        error_terminate(C, R, S)
    end.


try_cancel_observe_and_send_response(Request, Response, State) ->
    try_cancel_observe_and_send_response([], Request, Response, State).


try_cancel_observe_and_send_response(Ref, Request, Response, State=#state{module=Module, obstate=ObState}) ->
    try case coap_unobserve(Module, ObState) of
        ok ->
            State2 = cancel_observer(State),
            case Response of
                {error, Code} ->
                    return_response(Ref, Request, {error, Code}, <<>>, State2);
                #coap_content{} ->
                    return_resource(Ref, Request, {ok, 'Content'}, Response, State2)
            end
    end catch C:R:S ->
        send_server_error(Request, State),
        error_terminate(C, R, S)
    end.


cancel_observer(State=#state{observer=undefined}) ->
    State;

cancel_observer(State=#state{uri=Uri}) ->
    ok = pg2:leave({coap_observer, Uri}, self()),
    % will the last observer to leave this group please turn out the lights
    case pg2:get_members({coap_observer, Uri}) of
        [] -> pg2:delete({coap_observer, Uri});
        _Else -> ok
    end,
    State#state{observer=undefined, obstate=undefined}.


handle_post(EpID, Request, State=#state{prefix=Prefix, suffix=Suffix, module=Module}) ->
    try case coap_post(Module, EpID, Prefix, Suffix, Request) of
        {ok, Code, Content} ->
            return_resource([], Request, {ok, Code}, Content, State);
        {error, Error} ->
            return_response(Request, {error, Error}, State);
        {error, Error, Reason} ->
            return_response([], Request, {error, Error}, Reason, State)
    end catch C:R:S ->
        send_server_error(Request, State),
        error_terminate(C, R, S)
    end.


handle_put(EpID, Request, Content, State=#state{prefix=Prefix, suffix=Suffix, module=Module}) ->
    try case coap_put(Module, EpID, Prefix, Suffix, Request) of
        ok ->
            return_response(Request, created_or_changed(Content), State);
        {error, Error} ->
            return_response(Request, {error, Error}, State);
        {error, Error, Reason} ->
            return_response([], Request, {error, Error}, Reason, State)
    end catch C:R:S ->
        send_server_error(Request, State),
        error_terminate(C, R, S)
    end.


created_or_changed({error, 'NotFound'}) ->
    {ok, 'Created'};

created_or_changed(_Content) ->
    {ok, 'Changed'}.


handle_delete(EpID, Request, State=#state{prefix=Prefix, suffix=Suffix, module=Module}) ->
    try case coap_delete(Module, EpID, Prefix, Suffix, Request) of
        ok ->
            return_response(Request, {ok, 'Deleted'}, State);
        {error, Error} ->
            return_response(Request, {error, Error}, State);
        {error, Error, Reason} ->
            return_response([], Request, {error, Error}, Reason, State)
    end catch C:R:S ->
        send_server_error(Request, State),
        error_terminate(C, R, S)
    end.


return_resource(Request, Content, State) ->
    return_resource([], Request, {ok, 'Content'}, Content, State).


return_resource(Ref, Request, {ok, Code}, Content=#coap_content{payload=Payload, options=Options}, State=#state{config=#{max_block_size:=MaxBlockSize}}) ->
    ETag = get_etag(Options),
    Response = case lists:member(ETag, coap_message:get_option('ETag', Request, [])) of
            true ->
                coap_message:set_option('ETag', [ETag],
                    ecoap_request:response({ok, 'Valid'}, Request));
            false ->
                ecoap_request:set_payload(Payload, coap_message:get_option('Block2', Request), 
                    coap_message:merge_options(Options, ecoap_request:response({ok, Code}, Request)), MaxBlockSize)
    end,
    send_observable(Ref, Request, Response, State#state{last_response={ok, Code, Content}}). 


send_observable(Ref, _Request, Response, State=#state{observer=undefined}) ->
    send_response(Ref, Response, State);

send_observable(Ref, Request=#coap_message{token=Token}, Response, State=#state{observer=Observer, obseq=Seq}) ->
    case {coap_message:get_option('Observe', Request), Observer} of
        % when requested observe and is observing, return the sequence number
        {0, #coap_message{token=Token}} ->
            send_response(Ref, coap_message:set_option('Observe', Seq, Response), State#state{obseq=next_seq(Seq)});
        _Else ->
            send_response(Ref, Response, State)
    end.       


return_response(Request, Code, State) ->
    return_response([], Request, Code, <<>>, State).


return_response(Ref, Request, Code, Reason, State) ->
    send_response(Ref, ecoap_request:response(Code, Reason, Request), State#state{last_response=Code}).


send_response(Ref, Response, State=#state{config=#{endpoint_pid:=EndpointPid, exchange_lifetime:=TimeOut}, observer=Observer, id=ID}) ->
    % io:fwrite("<- ~p~n", [Response]),
    {ok, _} = ecoap_endpoint:send_response(EndpointPid, Ref, Response),
    case coap_message:get_option('Block2', Response) of
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
    _ = erlang:cancel_timer(Timer),
    set_timeout0(State, Timeout).


set_timeout0(State, Timeout) ->
    TRef = erlang:start_timer(Timeout, self(), cache_expired),
    {noreply, State#state{timer=TRef}}.


next_seq(Seq) ->
    if
        Seq < 16#0FFF -> Seq+1;
        true -> 0
    end.


get_etag(Options) ->
    case coap_message:get_option('ETag', Options) of
        [ETag] -> ETag;
        _ -> undefined
    end.


coap_get(Module, EpID, Prefix, Suffix, Query, Request) ->
    case erlang:function_exported(Module, coap_get, 5) of
        true -> Module:coap_get(EpID, Prefix, Suffix, Query, Request);
        false -> {error, 'MethodNotAllowed'}
    end.


coap_post(Module, EpID, Prefix, Suffix, Request) ->
    case erlang:function_exported(Module, coap_post, 4) of
        true -> Module:coap_post(EpID, Prefix, Suffix, Request);
        false -> {error, 'MethodNotAllowed'}
    end.


coap_put(Module, EpID, Prefix, Suffix, Request) ->
    case erlang:function_exported(Module, coap_put, 4) of
        true -> Module:coap_put(EpID, Prefix, Suffix, Request);
        false -> {error, 'MethodNotAllowed'}
    end.


coap_delete(Module, EpID, Prefix, Suffix, Request) ->
    case erlang:function_exported(Module, coap_delete, 4) of
        true -> Module:coap_delete(EpID, Prefix, Suffix, Request);
        false -> {error, 'MethodNotAllowed'}
    end.


coap_observe(Module, EpID, Prefix, Suffix, Request) ->
    case erlang:function_exported(Module, coap_observe, 4) of
        true -> Module:coap_observe(EpID, Prefix, Suffix, Request);
        false -> {error, 'MethodNotAllowed'}
    end.


coap_unobserve(Module, ObState) ->
    case erlang:function_exported(Module, coap_unobserve, 1) of
        true -> Module:coap_unobserve(ObState);
        false -> ok
    end.


handle_info(Module, Info, ObsReq, ObState) ->
    case erlang:function_exported(Module, handle_info, 3) of
        true -> Module:handle_info(Info, ObsReq, ObState);
        false ->
            case Info of
                {coap_notify, Msg} -> {notify, Msg, ObState};
                _ -> {noreply, ObState}
            end
    end.


coap_ack(Module, Ref, ObState) ->
    case erlang:function_exported(Module, coap_ack, 2) of
        true -> Module:coap_ack(Ref, ObState);
        false -> {ok, ObState}
    end.


send_server_error(Request, State) ->
    send_server_error([], Request, State).


send_server_error(Ref, Request, State=#state{config=#{endpoint_pid:=EndpointPid}}) ->
    _ = cancel_observer(State),
    {ok, _} = ecoap_endpoint:send_response(EndpointPid, Ref, ecoap_request:response({error, 'InternalServerError'}, <<>>, Request)),
    ok.


error_terminate(Class, {case_clause, BadReply}, Stacktrace) ->
    erlang:raise(Class, {bad_return_value, BadReply}, Stacktrace);

error_terminate(Class, Reason, Stacktrace) ->
    erlang:raise(Class, Reason, Stacktrace).
