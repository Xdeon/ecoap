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

-define(EXCHANGE_LIFETIME, 247000).

-include("coap_message.hrl").
-include("coap_content.hrl").

-record(state, {
	endpoint_pid = undefined :: pid(),
    id = undefined :: {atom(), [binary()], [binary()]},
	uri = undefined :: [binary()],
	prefix = undefined :: [binary()], 
	suffix = undefined :: [binary()],
	query = undefined :: [binary()],
	module = undefined :: module(), 
	insegs = undefined :: {orddict:orddict(), undefined | binary() | non_neg_integer()}, 
	last_response = undefined :: last_response(),
	observer = undefined :: undefined | coap_message:coap_message(), 
	obseq = undefined :: non_neg_integer(), 
	obstate = undefined :: any(), 
	timer = undefined :: undefined | reference()}).

-type last_response() ::
    undefined |
    {ok, coap_message:success_code(), coap_content:coap_content()} |
    coap_message:coap_success() | 
    coap_message:coap_error().

-include("ecoap.hrl").

%% API.

-spec start_link(pid(), {atom(), [binary()], [binary()]}) -> {ok, pid()}.
start_link(EndpointPid, ID) ->
	gen_server:start_link(?MODULE, [EndpointPid, ID], []).

close(Pid) ->
    gen_server:cast(Pid, shutdown).

-spec notify([binary()], any()) -> ok.
notify(Uri, Info) ->
    case pg2:get_members({coap_observer, Uri}) of
        {error, _} -> ok;
        List -> [gen_server:cast(Pid, {coap_notify, Info}) || Pid <- List], ok
    end.

%% gen_server.

init([EndpointPid, ID={_, Uri, Query}]) ->
    % the receiver will be determined based on the URI
    case ecoap_registry:match_handler(Uri) of
        {Prefix, Module} ->
        	% %io:fwrite("Prefix:~p Uri:~p~n", [Prefix, Uri]),
            ecoap_endpoint:monitor_handler(EndpointPid, self()),
            {ok, #state{endpoint_pid=EndpointPid, id=ID, uri=Uri, prefix=Prefix, suffix=uri_suffix(Prefix, Uri), query=Query, module=Module,
                insegs={orddict:new(), undefined}, obseq=0}};
        undefined ->
            % use shutdown as reason to avoid crash report logging
            {stop, shutdown}
    end.

handle_call(_Request, _From, State) ->
    error_logger:error_msg("unexpected call ~p received by ~p as ~p~n", [_Request, self(), ?MODULE]),
	{noreply, State}.

handle_cast({coap_notify, _Info}, State=#state{observer=undefined}) ->
    % ignore unexpected notification
    {noreply, State};
handle_cast({coap_notify, Info}, State=#state{observer=Observer, module=Module, obstate=ObState}) ->
    case coap_resource:handle_notify(Module, Info, Observer, ObState) of
        {ok, {error, Code}, ObState2} ->
            {ok, State2} = cancel_observer(Observer, State#state{obstate=ObState2}),
            return_response(Observer, {error, Code}, State2);
        {ok, Content, ObState2} ->
            return_resource(Observer, Content, State#state{obstate=ObState2});
        % server internal error
        {error, Error} ->
            {ok, State2} = cancel_observer(Observer, State),
            return_response(Observer, {error, Error}, State2)
    end;
handle_cast(shutdown, State=#state{observer=undefined}) ->
    {stop, normal, State};
handle_cast(shutdown, State=#state{observer=Observer}) ->
    {ok, State2} = cancel_observer(Observer, State),
    {stop, normal, State2};
handle_cast(_Msg, State) ->
    error_logger:error_msg("unexpected cast ~p received by ~p as ~p~n", [_Msg, self(), ?MODULE]),
	{noreply, State}.

handle_info({coap_request, EpID, _EndpointPid, _Receiver=undefined, Request}, State) ->
    handle(EpID, Request, State);
handle_info({timeout, TRef, cache_expired}, State=#state{observer=undefined, timer=TRef}) ->
    {stop, normal, State};
handle_info({timeout, TRef, cache_expired}, State=#state{timer=TRef}) ->
    % multi-block cache expired, but the observer is still active
    {noreply, State};
handle_info(_Info, State=#state{observer=undefined}) ->
    {noreply, State};
handle_info({coap_ack, _EpID, _EndpointPid, Ref}, State=#state{module=Module, obstate=ObState}) ->
    {ok, ObState2} = coap_resource:coap_ack(Module, Ref, ObState),
    {noreply, State#state{obstate=ObState2}};
handle_info({coap_error, _EpID, _EndpointPid, _Ref, _Error}, State=#state{observer=Observer}) ->
    {ok, State2} = cancel_observer(Observer, State),
    {stop, normal, State2};
handle_info(Info, State=#state{module=Module, observer=Observer, obstate=ObState}) ->
    case coap_resource:handle_info(Module, Info, Observer, ObState) of
        {notify, Ref, {error, Code}, ObState2} ->
            % should we wait for ack (of the error response, if applicable) before terminate?
            {ok, State2} = cancel_observer(Observer, State#state{obstate=ObState2}),
            return_response(Ref, Observer, {error, Code}, <<>>, State2);
        {notify, Ref, Content, ObState2} ->
            return_resource(Ref, Observer, {ok, 'Content'}, Content, State#state{obstate=ObState2});
        {noreply, ObState2} ->
            {noreply, State#state{obstate=ObState2}};
        {stop, ObState2} ->
            {ok, State2} = cancel_observer(Observer, State#state{obstate=ObState2}),
            return_response(Observer, {error, 'ServiceUnavailable'}, State2);
        % server internal error
        {error, Error} ->
            {ok, State2} = cancel_observer(Observer, State),
            return_response(Observer, {error, Error}, State2)
    end.

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

handle(EpID, Request, State=#state{endpoint_pid=EndpointPid, id=ID}) ->
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
            set_timeout(?EXCHANGE_LIFETIME, State2);
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

process_blocks(#coap_message{payload=Segment}, {Num, true, Size}, State=#state{insegs={Segs, Format}}) ->
    case byte_size(Segment) of
        Size when Num*Size < ?MAX_BODY_SIZE -> {'Continue', State#state{insegs={orddict:store(Num, Segment, Segs), Format}}};
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
    case coap_resource:coap_get(Module, EpID, Prefix, Suffix, Query, Request) of
        {ok, Content} ->
            check_preconditions(EpID, Request, Content, State);
        {error, 'NotFound'} = R ->
            check_preconditions(EpID, Request, R, State);
        {error, Code} ->
            return_response(Request, {error, Code}, State);
        {error, Code, Reason} ->
            return_response([], Request, {error, Code}, Reason, State)
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
        State=#state{endpoint_pid=EndpointPid, id=ID, prefix=Prefix, suffix=Suffix, uri=Uri, module=Module, observer=undefined}) ->
    % the first observe request from this user to this resource
    case coap_resource:coap_observe(Module, EpID, Prefix, Suffix, Request) of
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
    end;
handle_observe(_EpID, Request, Content, State) ->
    % subsequent observe request from the same user
    return_resource(Request, Content, State#state{observer=Request}).

handle_unobserve(_EpID, Request=#coap_message{token=Token}, Content, State=#state{observer=#coap_message{token=Token}}) ->
    {ok, State2} = cancel_observer(Request, State),
    return_resource(Request, Content, State2);
handle_unobserve(_EpID, Request, Content, State) ->
    return_resource(Request, Content, State).

cancel_observer(_Request, State=#state{uri=Uri, module=Module, obstate=ObState}) ->
    ok = coap_resource:coap_unobserve(Module, ObState),
    ok = pg2:leave({coap_observer, Uri}, self()),
    % will the last observer to leave this group please turn out the lights
    case pg2:get_members({coap_observer, Uri}) of
        [] -> pg2:delete({coap_observer, Uri});
        _Else -> ok
    end,
    {ok, State#state{observer=undefined, obstate=undefined}}.

handle_post(EpID, Request, State=#state{prefix=Prefix, suffix=Suffix, module=Module}) ->
    case coap_resource:coap_post(Module, EpID, Prefix, Suffix, Request) of
        {ok, Code, Content} ->
            return_resource([], Request, {ok, Code}, Content, State);
        {error, Error} ->
            return_response(Request, {error, Error}, State);
        {error, Error, Reason} ->
            return_response([], Request, {error, Error}, Reason, State)
    end.

handle_put(EpID, Request, Content, State=#state{prefix=Prefix, suffix=Suffix, module=Module}) ->
    case coap_resource:coap_put(Module, EpID, Prefix, Suffix, Request) of
        ok ->
            return_response(Request, created_or_changed(Content), State);
        {error, Error} ->
            return_response(Request, {error, Error}, State);
        {error, Error, Reason} ->
            return_response([], Request, {error, Error}, Reason, State)
    end.

created_or_changed({error, 'NotFound'}) ->
    {ok, 'Created'};
created_or_changed(_Content) ->
    {ok, 'Changed'}.

handle_delete(EpID, Request, State=#state{prefix=Prefix, suffix=Suffix, module=Module}) ->
    case coap_resource:coap_delete(Module, EpID, Prefix, Suffix, Request) of
        ok ->
            return_response(Request, {ok, 'Deleted'}, State);
        {error, Error} ->
            return_response(Request, {error, Error}, State);
        {error, Error, Reason} ->
            return_response([], Request, {error, Error}, Reason, State)
    end.

return_resource(Request, Content, State) ->
    return_resource([], Request, {ok, 'Content'}, Content, State).

return_resource(Ref, Request, {ok, Code}, Content=#coap_content{payload=Payload, options=Options}, State) ->
    ETag = get_etag(Options),
    Response = case lists:member(ETag, coap_message:get_option('ETag', Request, [])) of
            true ->
                coap_message:set_option('ETag', [ETag],
                    ecoap_request:response({ok, 'Valid'}, Request));
            false ->
                ecoap_request:set_payload(Payload, coap_message:get_option('Block2', Request), 
                    coap_message:merge_options(Options, ecoap_request:response({ok, Code}, Request)))
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

send_response(Ref, Response, State=#state{endpoint_pid=EndpointPid, observer=Observer, id=ID}) ->
    % io:fwrite("<- ~p~n", [Response]),
    {ok, _} = ecoap_endpoint:send_response(EndpointPid, Ref, Response),
    case Observer of
        undefined ->
            case coap_message:get_option('Block2', Response) of
                {_, true, _} ->
                    % client is expected to ask for more blocks
                    ecoap_endpoint:register_handler(EndpointPid, ID, self()),
                    set_timeout(?EXCHANGE_LIFETIME, State);
                _Else ->
                    % no further communication concerning this request
                    {stop, normal, State}
            end;
        _ ->
            % notifications will follow
            {noreply, State}
    end.

set_timeout(Timeout, State=#state{timer=undefined}) ->
    set_timeout0(State, Timeout);
set_timeout(Timeout, State=#state{timer=Timer}) ->
    _ = erlang:cancel_timer(Timer),
    set_timeout0(State, Timeout).

set_timeout0(State, Timeout) ->
    % Timer = erlang:send_after(Timeout, self(), cache_expired),
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

% uri_suffix(Prefix, #coap_message{options=Options}) ->
%     Uri = coap_message:get_option('Uri-Path', Options, []),
%     lists:nthtail(length(Prefix), Uri).

% uri_query(#coap_message{options=Options}) ->
%     coap_message:get_option('Uri-Query', Options, []).

uri_suffix(Prefix, Uri) ->
	lists:nthtail(length(Prefix), Uri).

% invoke_callback(Module, Fun, Args) ->
%     case catch {ok, apply(Module, Fun, Args)} of
%         {ok, Response} ->
%             Response;
%         {'EXIT', Error} ->
%             error_logger:error_msg("~p", [Error]),
%             {error, 'InternalServerError'}
%     end.
