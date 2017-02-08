-module(test_resource).
-export([coap_discover/2, coap_get/5, coap_post/4, coap_put/4, coap_delete/3, coap_observe/4, coap_unobserve/1, handle_info/2, coap_ack/2]).
-export([start/0, stop/0]).

-include("coap_def.hrl").
-behaviour(coap_resource).

start() ->
    _ = application:stop(ecoap),
    _ = application:stop(mnesia),
    ok = application:start(mnesia),
    {atomic, ok} = mnesia:create_table(resources, []),
    {ok, _} = application:ensure_all_started(ecoap),
    ok = ecoap_registry:register_handler([], ?MODULE, undefined).

stop() ->
    ok = application:stop(ecoap),
    ok = application:stop(mnesia).

% resource operations
coap_discover(Prefix, _Args) ->
    io:format("discover ~p~n", [Prefix]),
    [{absolute, Prefix++Name, []} || Name <- mnesia:dirty_all_keys(resources)].

coap_get(_EpID, Prefix, Name, Query, _Accept) ->
    io:format("get ~p ~p ~p~n", [Prefix, Name, Query]),
    case mnesia:dirty_read(resources, Name) of
        [{resources, Name, Resource}] -> Resource;
        [] -> {error, 'NotFound'}
    end.

coap_post(_EpID, Prefix, Name, Content) ->
    io:format("post ~p ~p ~p~n", [Prefix, Name, Content]),
    {error, 'MethodNotAllowed'}.

coap_put(_EpID, Prefix, Name, Content) ->
    io:format("put ~p ~p ~p~n", [Prefix, Name, Content]),
    mnesia:dirty_write(resources, {resources, Name, Content}),
    _ = coap_handler:notify(Prefix++Name, Content),
    ok.

coap_delete(_EpID, Prefix, Name) ->
    io:format("delete ~p ~p~n", [Prefix, Name]),
    mnesia:dirty_delete(resources, Name),
    _ = coap_handler:notify(Prefix++Name, {error, 'NotFound'}),
    ok.

coap_observe(_EpID, Prefix, Name, _Ack) ->
    io:format("observe ~p ~p~n", [Prefix, Name]),
    {ok, {state, Prefix, Name}}.
    % {error, 'MethodNotAllowed'}.

coap_unobserve({state, Prefix, Name}) ->
    io:format("unobserve ~p ~p~n", [Prefix, Name]),
    ok.

handle_info(_Message, State) -> {noreply, State}.
coap_ack(_Ref, State) -> {ok, State}.

