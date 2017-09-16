-module(test_resource).
-export([coap_discover/2, coap_get/5, coap_post/4, coap_put/4, coap_delete/4, 
        coap_observe/4, coap_unobserve/1, handle_notify/3, handle_info/3, coap_ack/2]).
-export([start/0, stop/0]).

-behaviour(coap_resource).

-include("ecoap.hrl").

-record(coap_content, {
    etag = undefined :: undefined | binary(),
    max_age = ?DEFAULT_MAX_AGE :: non_neg_integer(),
    format = undefined :: undefined | binary() | non_neg_integer(),
    payload = <<>> :: binary()
}).

start() ->
    _ = application:stop(ecoap),
    _ = application:stop(mnesia),
    ok = application:start(mnesia),
    {atomic, ok} = mnesia:create_table(resources, []),
    {ok, _} = application:ensure_all_started(ecoap),
    ok = ecoap_registry:register_handler([{[], ?MODULE, undefined}]).

stop() ->
    ok = application:stop(ecoap),
    ok = application:stop(mnesia).

% resource operations
coap_discover(Prefix, _Args) ->
    io:format("discover ~p~n", [Prefix]),
    [{absolute, Prefix++Name, []} || Name <- mnesia:dirty_all_keys(resources)].

coap_get(_EpID, Prefix, Name, Query, Request) ->
    Accept = coap_message:get_option('Accept', Request),
    io:format("get ~p ~p ~p accept ~p~n", [Prefix, Name, Query, Accept]),
    case mnesia:dirty_read(resources, Name) of
        [{resources, Name, Content}] -> 
            {Payload, Options} = content_to_response(Content),
            {ok, Payload, Options};
        [] -> 
            {error, 'NotFound'}
    end.

coap_post(_EpID, Prefix, Name, Request) -> 
    Content = get_content(Request),
    io:format("post ~p ~p ~p~n", [Prefix, Name, Content]),
    {error, 'MethodNotAllowed'}.
    % {ok, 'Created', coap_content:set_options(#{'Location-Path' => Prefix++Name}, coap_content:new())}.

coap_put(_EpID, Prefix, Name, Request) ->
    Content = get_content(Request),
    io:format("put ~p ~p ~p~n", [Prefix, Name, Content]),
    mnesia:dirty_write(resources, {resources, Name, Content}),
    ecoap_handler:notify(Prefix++Name, Content),
    ok.

coap_delete(_EpID, Prefix, Name, _Request) ->
    io:format("delete ~p ~p~n", [Prefix, Name]),
    mnesia:dirty_delete(resources, Name),
    ecoap_handler:notify(Prefix++Name, {error, 'NotFound'}),
    ok.

coap_observe(_EpID, Prefix, Name, Request) ->
    RequireAck = ecoap_request:requires_ack(Request),
    io:format("observe ~p ~p requires ack ~p~n", [Prefix, Name, RequireAck]),
    {ok, {state, Prefix, Name}}.
    % {error, 'MethodNotAllowed'}.

coap_unobserve({state, Prefix, Name}) ->
    io:format("unobserve ~p ~p~n", [Prefix, Name]),
    ok.

handle_notify(Notification, _ObsReq, State) ->
    {ok, Notification, State}.

handle_info(_Info, _ObsReq, State) -> 
    {noreply, State}.

coap_ack(_Ref, State) -> {ok, State}.


get_content(#{options:=Options, payload:=Payload}) ->
    #coap_content{
        etag = case coap_message:get_option('ETag', Options) of
                   [ETag] -> ETag;
                   _ -> undefined
            end,
        max_age = coap_message:get_option('Max-Age', Options, ?DEFAULT_MAX_AGE),
        format = coap_message:get_option('Content-Format', Options),
        payload = Payload}.

content_to_response(#coap_content{etag=ETag, max_age=MaxAge, format=Format, payload=Payload}) ->
    {Payload, #{'ETag' => ETag, 'Max-Age' => MaxAge, 'Content-Format' => Format}}.
