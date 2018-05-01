-module(empty_server_test).
-behaviour(ecoap_handler).

-export([coap_discover/1, coap_get/5, coap_post/4, coap_put/4, coap_delete/4, 
        coap_observe/4, coap_unobserve/1, handle_info/3, coap_ack/2]).

-include_lib("eunit/include/eunit.hrl").
-include_lib("src/coap_content.hrl").

coap_discover(_Prefix) -> [].

coap_get(_EpID, _Prefix, _Suffix, _Query, _Request) -> {error, 'MethodNotAllowed'}.
coap_post(_EpID, _Prefix, _Suffix, _Request) -> {error, 'MethodNotAllowed'}.
coap_put(_EpID, _Prefix, _Suffix, _Request) -> {error, 'MethodNotAllowed'}.
coap_delete(_EpID, _Prefix, _Suffix, _Request) -> {error, 'MethodNotAllowed'}.

coap_observe(_EpID, _Prefix, _Suffix, _Request) -> {error, 'MethodNotAllowed'}.
coap_unobserve(_State) -> ok.
handle_info(_Message, _ObsReq, State) -> {noreply, State}.
coap_ack(_Ref, State) -> {ok, State}.

% fixture is my friend
empty_server_test_() ->
    {setup,
        fun() ->
            {ok, _} = application:ensure_all_started(ecoap),
            {ok, _} = ecoap:start_udp(?MODULE, [], #{routes => []}),
            {ok, Client} = ecoap_client:open(),
            Client
        end,
        fun(Client) ->
            application:stop(ecoap),
            ecoap_client:close(Client)
        end,
        fun empty_server/1}.

empty_server(Client) ->
    [
    % provoked reset
    ?_assertEqual(ok, ecoap_client:ping(Client, "coap://127.0.0.1")),
    % discovery
    ?_assertEqual({ok, {error, 'NotFound'}, #coap_content{}}, ecoap_client:get(Client, "coap://127.0.0.1")),
    ?_assertEqual({ok, {error, 'NotFound'}, #coap_content{}}, ecoap_client:get(Client, "coap://127.0.0.1/.well-known")),
    ?_assertMatch({ok, {ok, 'Content'}, #coap_content{payload= <<>>}}, ecoap_client:get(Client, "coap://127.0.0.1/.well-known/core")),
    % other methods
    ?_assertEqual({ok, {error, 'MethodNotAllowed'}, #coap_content{}}, ecoap_client:post(Client, "coap://127.0.0.1/.well-known/core", <<>>)),
    ?_assertEqual({ok, {error, 'MethodNotAllowed'}, #coap_content{}}, ecoap_client:put(Client, "coap://127.0.0.1/.well-known/core", <<>>)),
    ?_assertEqual({ok, {error, 'MethodNotAllowed'}, #coap_content{}}, ecoap_client:delete(Client, "coap://127.0.0.1/.well-known/core"))
    ].


unknown_handler_test_() ->
    {setup,
        fun() ->
            {ok, _} = application:ensure_all_started(ecoap),
            {ok, _} = ecoap:start_udp(?MODULE, [], #{routes => [{[<<"unknown">>], unknown_module}]}),
            {ok, Client} = ecoap_client:open(),
            Client
        end,
        fun(Client) ->
            application:stop(ecoap),
            ecoap_client:close(Client)
        end,
        fun unknown_handler/1}.

unknown_handler(Client) ->
    [
    ?_assertMatch({ok, {ok, 'Content'}, #coap_content{payload= <<"</unknown>">>}}, ecoap_client:get(Client, "coap://127.0.0.1/.well-known/core")),
    ?_assertEqual({ok, {error,'MethodNotAllowed'}, #coap_content{}}, ecoap_client:get(Client, "coap://127.0.0.1/unknown"))
    ].

% end of file
