-module(test_resource).
-export([coap_discover/1, coap_get/4, coap_post/4, coap_put/4, coap_delete/4, 
        coap_observe/4, coap_unobserve/1, handle_info/3, coap_ack/2]).
-export([start/1, stop/0]).

-behaviour(ecoap_handler).

start(Port) ->
    ok = application:start(mnesia),
    {atomic, ok} = mnesia:create_table(resources, []),
    {ok, _} = application:ensure_all_started(ecoap),
    ecoap:start_udp(test_server, [{port, Port}],
        #{routes => [{[<<"*">>], ?MODULE}], protocol_config => #{max_block_size => 64}}).

stop() ->
    ok = application:stop(ecoap),
    ok = application:stop(mnesia).

% resource operations
coap_discover(Prefix) ->
    io:format("discover ~p~n", [Prefix]),
    [{absolute, Prefix++Name, []} || Name <- mnesia:dirty_all_keys(resources)].

coap_get(_EpID, Prefix, Name, Request) ->
    Accept = ecoap_request:accept(Request),
    Query = ecoap_request:query(Request),
    io:format("get ~p ~p ~p accept ~p~n", [Prefix, Name, Query, Accept]),
    case mnesia:dirty_read(resources, Name) of
        [{resources, Name, Content}] -> {ok, Content};
        [] -> {error, 'NotFound'}
    end.

coap_post(_EpID, Prefix, Name, Request) -> 
    Content = ecoap_content:get_content(Request),
    io:format("post ~p ~p ~p~n", [Prefix, Name, Content]),
    {error, 'MethodNotAllowed'}.
    % {ok, 'Created', ecoap_content:set_options(#{'Location-Path' => Prefix++Name}, ecoap_content:new())}.

coap_put(_EpID, Prefix, Name, Request) ->
    Content = ecoap_content:get_content(Request),
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

handle_info({coap_notify, Msg}, _ObsReq, State) ->
    {notify, Msg, State};
handle_info(_Info, _ObsReq, State) ->
    {noreply, State}.

coap_ack(_Ref, State) -> {ok, State}.