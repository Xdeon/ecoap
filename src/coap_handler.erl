-module(coap_handler).
-behaviour(gen_server).

%% API.
-export([start_link/3]).
-compile([export_all]).

%% gen_server.
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-define(EXCHANGE_LIFETIME, 247000).

-record(state, {
	endpoint_pid = undefined :: pid(),
	uri = undefined :: list(binary()),
	prefix = undefined :: list(binary()), 
	suffix = undefined :: list(binary()),
	query = undefined :: undefined | list(binary()),
	module = undefined :: module(), 
	args = undefined :: any(), 
	insegs = undefined :: orddict:orddict(), 
	last_response = undefined :: undefined | {ok, _, _} | {error, _}, 
	observer = undefined :: any(), 
	obseq = undefined :: non_neg_integer(), 
	obstate = undefined :: any(), 
	timer = undefined :: undefined | reference()}).

-include("coap_def.hrl").

%% API.

-spec start_link(pid(), list(binary()), list(binary())) -> {ok, pid()}.
start_link(EndpointPid, Uri, Query) ->
	gen_server:start_link(?MODULE, [EndpointPid, Uri, Query], []).

notify(Uri, Resource) ->
    case pg2:get_members({coap_observer, Uri}) of
        {error, _} -> ok;
        List -> [gen_server:cast(Pid, {obs_notify, Resource}) || Pid <- List]
    end.

%% gen_server.

init([EndpointPid, Uri, Query]) ->
    % the receiver will be determined based on the URI
    case ecoap_registry:match_handler(Uri) of
        {Prefix, Module, Args} ->
        	% io:fwrite("Prefix:~p Uri:~p~n", [Prefix, Uri]),
            % EndpointPid ! {handler_started, self()},
            {ok, #state{endpoint_pid=EndpointPid, uri=Uri, prefix=Prefix, suffix=uri_suffix(Prefix, Uri), query=Query, module=Module, args=Args,
                insegs=orddict:new(), obseq=0}};
        undefined ->
            {stop, not_found}
    end.

handle_call(_Request, _From, State) ->
	{reply, ignored, State}.

handle_cast({obs_notify, _Resource}, State=#state{observer=undefined}) ->
    % ignore unexpected notification
    {noreply, State};
handle_cast({obs_notify, Resource=#coap_content{}}, State=#state{observer=Observer}) ->
    return_resource(Observer, Resource, State);
handle_cast({obs_notify, {error, Code}}, State=#state{observer=Observer}) ->
    {ok, State2} = cancel_observer(Observer, State),
    return_response(Observer, {error, Code}, State2);
handle_cast(_Msg, State) ->
	{noreply, State}.

handle_info({timeout, TRef, cache_expired}, State=#state{observer=undefined, timer=TRef}) ->
    {stop, normal, State};
handle_info({timeout, TRef, cache_expired}, State=#state{timer=TRef}) ->
    % multi-block cache expired, but the observer is still active
    {noreply, State};
handle_info({coap_request, EpID, _EndpointPid, _Receiver=undefined, Request}, State) ->
	handle(EpID, Request, State);
handle_info({coap_ack, _EpID, _EndpointPid, Ref},
        State=#state{module=Module, obstate=ObState}) ->
    case invoke_callback(Module, coap_ack, [Ref, ObState]) of
        {ok, ObState2} ->
            {noreply, State#state{obstate=ObState2}}
    end;
handle_info({coap_error, _EpID, _EndpointPid, _Ref, _Error}, State=#state{observer=Observer}) ->
    {ok, State2} = cancel_observer(Observer, State),
    {stop, normal, State2};
handle_info(_Info, State=#state{observer=undefined}) ->
	{noreply, State};
handle_info(Info, State=#state{module=Module, observer=Observer, obstate=ObState}) ->
    case invoke_callback(Module, handle_info, [Info, ObState]) of
        {notify, Ref, Resource=#coap_content{}, ObState2} ->
            return_resource(Ref, Observer, {ok, 'CONTENT'}, Resource, State#state{obstate=ObState2});
        {notify, Ref, {error, Code}, ObState2} ->
            return_response(Ref, Observer, {error, Code}, <<>>, State#state{obstate=ObState2});
        {noreply, ObState2} ->
            {noreply, State#state{obstate=ObState2}};
        {stop, ObState2} ->
            {ok, State2} = cancel_observer(Observer, State#state{obstate=ObState2}),
            return_response(Observer, {error, 'SERVICE_UNAVAILABLE'}, State2)
    end.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%% Internal

handle(EpID, Request=#coap_message{options=Options}, State=#state{endpoint_pid=EndpointPid}) ->
	Block1 = proplists:get_value('Block1', Options),
    case catch assemble_payload(Request, Block1, State) of
        {error, Code} ->
            return_response(Request, {error, Code}, State);
        {continue, State2} ->
            {ok, _} = coap_endpoint:send_response(EndpointPid, [],
                coap_message_utils:set('Block1', Block1,
                    coap_message_utils:response({ok, 'CONTINUE'}, Request))),
            set_timeout(?EXCHANGE_LIFETIME, State2);
        {ok, Payload, State2} ->
            process_request(EpID, Request#coap_message{payload=Payload}, State2)
    end.

assemble_payload(#coap_message{payload=Payload}, undefined, State) ->
    {ok, Payload, State};
assemble_payload(#coap_message{payload=Segment}, {Num, true, Size}, State=#state{insegs=Segs}) ->
    case byte_size(Segment) of
        Size -> {continue, State#state{insegs=orddict:store(Num, Segment, Segs)}};
        _Else -> {error, 'BAD_REQUEST'}
    end;
assemble_payload(#coap_message{payload=Segment}, {_Num, false, _Size}, State=#state{insegs=Segs}) ->
    Payload = lists:foldl(
        fun ({Num1, Segment1}, Acc) when Num1*byte_size(Segment1) == byte_size(Acc) ->
                <<Acc/binary, Segment1/binary>>;
            (_Else, _Acc) ->
                throw({error, 'REQUEST_ENTITY_INCOMPLETE'})
        end, <<>>, orddict:to_list(Segs)),
    {ok, <<Payload/binary, Segment/binary>>, State#state{insegs=orddict:new()}}.

process_request(EpID, Request=#coap_message{options=Options},
        State=#state{last_response={ok, Code, Content}}) ->
    case proplists:get_value('Block2', Options) of
        {N, _, _} when N > 0 ->
            return_resource([], Request, {ok, Code}, Content, State);
        _Else ->
            check_resource(EpID, Request, State)
    end;
process_request(EpID, Request, State) ->
    check_resource(EpID, Request, State).

check_resource(EpID, Request, State=#state{prefix=Prefix, suffix=Suffix, query=Query, module=Module}) ->
    case invoke_callback(Module, coap_get,
            [EpID, Prefix, Suffix, Query]) of
        R1=#coap_content{} ->
            check_preconditions(EpID, Request, R1, State);
        R2={error, 'NOT_FOUND'} ->
            check_preconditions(EpID, Request, R2, State);
        {error, Code} ->
            return_response(Request, {error, Code}, State);
        {error, Code, Reason} ->
            return_response([], Request, {error, Code}, Reason, State)
    end.

check_preconditions(EpID, Request, Resource, State) ->
    case if_match(Request, Resource) and if_none_match(Request, Resource) of
        true ->
            handle_method(EpID, Request, Resource, State);
        false ->
            return_response(Request, {error, 'PRECONDITION_FAILED'}, State)
    end.

if_match(#coap_message{options=Options}, #coap_content{etag=ETag}) ->
    case proplists:get_value('If-Match', Options, []) of
        % empty string matches any existing representation
        [] -> true;
        % match exact resources
        List -> lists:member(ETag, List)
    end;
if_match(#coap_message{options=Options}, {error, 'NOT_FOUND'}) ->
    not proplists:is_defined('If-Match', Options).

if_none_match(#coap_message{options=Options}, #coap_content{}) ->
    not proplists:is_defined('If-None-Match', Options);
if_none_match(#coap_message{}, {error, _}) ->
    true.

handle_method(EpID, Request=#coap_message{code='GET', options=Options}, Resource=#coap_content{}, State) ->
     case proplists:get_value('Observe', Options) of
        0 ->
            handle_observe(EpID, Request, Resource, State);
        1 ->
            handle_unobserve(EpID, Request, Resource, State);
        undefined ->
            return_resource(Request, Resource, State);
        _Else ->
            return_response(Request, {error, 'BAD_OPTION'}, State)
    end;

handle_method(_EpID, Request=#coap_message{code='GET'}, {error, Code}, State) ->
    return_response(Request, {error, Code}, State);

handle_method(EpID, Request=#coap_message{code='POST'}, _Resource, State) ->
    handle_post(EpID, Request, State);

handle_method(EpID, Request=#coap_message{code='PUT'}, Resource, State) ->
    handle_put(EpID, Request, Resource, State);

handle_method(EpID, Request=#coap_message{code='DELETE'}, _Resource, State) ->
    handle_delete(EpID, Request, State);

handle_method(_EpID, Request, _Resource, State) ->
    return_response(Request, {error, 'METHOD_NOT_ALLOWED'}, State).

handle_observe(EpID, Request, Content=#coap_content{},
        State=#state{prefix=Prefix, suffix=Suffix, uri=Uri, module=Module, observer=undefined}) ->
    % the first observe request from this user to this resource
    case invoke_callback(Module, coap_observe, [EpID, Prefix, Suffix, requires_ack(Request)]) of
        {ok, ObState} ->
            pg2:create({coap_observer, Uri}),
            ok = pg2:join({coap_observer, Uri}, self()),
            return_resource(Request, Content, State#state{observer=Request, obstate=ObState});
        {error, 'METHOD_NOT_ALLOWED'} ->
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

requires_ack(#coap_message{type='CON'}) -> true;
requires_ack(#coap_message{type='NON'}) -> false.

handle_unobserve(_EpID, Request, Resource, State) ->
    {ok, State2} = cancel_observer(Request, State),
    return_resource(Request, Resource, State2).

cancel_observer(#coap_message{}, State=#state{uri=Uri, module=Module, obstate=ObState}) ->
    ok = invoke_callback(Module, coap_unobserve, [ObState]),
    % Uri = proplists:get_value('Uri_Path', Options, []),
    ok = pg2:leave({coap_observer, Uri}, self()),
    % will the last observer to leave this group please turn out the lights
    case pg2:get_members({coap_observer, Uri}) of
        [] -> pg2:delete({coap_observer, Uri});
        _Else -> ok
    end,
    {ok, State#state{observer=undefined, obstate=undefined}}.

handle_post(EpID, Request, State=#state{prefix=Prefix, suffix=Suffix, module=Module}) ->
    Content = coap_message_utils:get_content(Request),
    case invoke_callback(Module, coap_post, [EpID, Prefix, Suffix, Content]) of
        {ok, Code, Content2} ->
            return_resource([], Request, {ok, Code}, Content2, State);
        {error, Error} ->
            return_response(Request, {error, Error}, State);
        {error, Error, Reason} ->
            return_response([], Request, {error, Error}, Reason, State)
    end.

handle_put(EpID, Request, Resource, State=#state{prefix=Prefix, suffix=Suffix, module=Module}) ->
    Content = coap_message_utils:get_content(Request),
    case invoke_callback(Module, coap_put, [EpID, Prefix, Suffix, Content]) of
        ok ->
            return_response(Request, created_or_changed(Resource), State);
        {error, Error} ->
            return_response(Request, {error, Error}, State);
        {error, Error, Reason} ->
            return_response([], Request, {error, Error}, Reason, State)
    end.

created_or_changed(#coap_content{}) ->
    {ok, 'CHANGED'};
created_or_changed({error, 'NOT_FOUND'}) ->
    {ok, 'CREATED'}.

handle_delete(EpID, Request, State=#state{prefix=Prefix, suffix=Suffix, module=Module}) ->
    case invoke_callback(Module, coap_delete, [EpID, Prefix, Suffix]) of
        ok ->
            return_response(Request, {ok, 'DELETED'}, State);
        {error, Error} ->
            return_response(Request, {error, Error}, State);
        {error, Error, Reason} ->
            return_response([], Request, {error, Error}, Reason, State)
    end.

return_resource(Request, Content, State) ->
    return_resource([], Request, {ok, 'CONTENT'}, Content, State).

return_resource(Ref, Request=#coap_message{options=Options}, {ok, Code}, Content=#coap_content{etag=ETag}, State) ->
    Response = case lists:member(ETag, proplists:get_value('ETag', Options, [])) of
            true ->
                coap_message_utils:set_content(#coap_content{etag=ETag},
                    coap_message_utils:response({ok, 'VALID'}, Request));
            false ->
                coap_message_utils:set_content(Content, proplists:get_value('Block2', Options),
                    coap_message_utils:response({ok, Code}, Request))
    end,
    send_observable(Ref, Request, Response, State#state{last_response={ok, Code, Content}}).

send_observable(Ref, #coap_message{token=Token, options=Options}, Response,
        State=#state{observer=Observer, obseq=Seq}) ->
    case {proplists:get_value('Observe', Options), Observer} of
        % when requested observe and is observing, return the sequence number
        {0, #coap_message{token=Token}} ->
            send_response(Ref, coap_message_utils:set('Observe', Seq, Response), State#state{obseq=next_seq(Seq)});
        _Else ->
            send_response(Ref, Response, State)
    end.    

return_response(Request, Code, State) ->
    return_response([], Request, Code, <<>>, State).

return_response(Ref, Request, Code, Reason, State) ->
    send_response(Ref, coap_message_utils:response(Code, Reason, Request), State#state{last_response=Code}).

send_response(Ref, Response=#coap_message{options=Options},
        State=#state{endpoint_pid=EndpointPid, observer=Observer}) ->
    %io:fwrite("<- ~p~n", [Response]),
    {ok, _} = coap_endpoint:send_response(EndpointPid, Ref, Response),
    case Observer of
        #coap_message{} ->
            % notifications will follow
            {noreply, State};
        undefined ->
            case proplists:get_value('Block2', Options) of
                {_, true, _} ->
                    % client is expected to ask for more blocks
                    set_timeout(?EXCHANGE_LIFETIME, State);
                _Else ->
                    % no further communication concerning this request
                    {stop, normal, State}
            end
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

% uri_suffix(Prefix, #coap_message{options=Options}) ->
%     Uri = proplists:get_value('Uri-Path', Options, []),
%     lists:nthtail(length(Prefix), Uri).

% uri_query(#coap_message{options=Options}) ->
%     proplists:get_value('Uri-Query', Options, []).

uri_suffix(Prefix, Uri) ->
	lists:nthtail(length(Prefix), Uri).

invoke_callback(Module, Fun, Args) ->
    case catch apply(Module, Fun, Args) of
        {'EXIT', Error} ->
            error_logger:error_msg("~p", [Error]),
            {error, 'INTERNAL_SERVER_ERROR'};
        Response ->
            Response
    end.
