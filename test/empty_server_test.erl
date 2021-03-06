-module(empty_server_test).
-behaviour(ecoap_handler).

-export([coap_discover/1, coap_get/4, coap_post/4, coap_put/4, coap_delete/4, coap_fetch/4, coap_patch/4, coap_ipatch/4,
        coap_observe/4, coap_unobserve/1, handle_info/3, coap_ack/2]).

-include_lib("eunit/include/eunit.hrl").
-include_lib("src/ecoap_content.hrl").

coap_discover(_Prefix) -> [].

coap_get(_EpID, _Prefix, _Suffix, _Request) -> {error, 'MethodNotAllowed'}.
coap_post(_EpID, _Prefix, _Suffix, _Request) -> {error, 'MethodNotAllowed'}.
coap_put(_EpID, _Prefix, _Suffix, _Request) -> {error, 'MethodNotAllowed'}.
coap_delete(_EpID, _Prefix, _Suffix, _Request) -> {error, 'MethodNotAllowed'}.

coap_fetch(_EpID, _Prefix, _Suffix, _Request) -> {error, 'MethodNotAllowed'}.
coap_patch(_EpID, _Prefix, _Suffix, _Request) -> {error, 'MethodNotAllowed'}.
coap_ipatch(_EpID, _Prefix, _Suffix, _Request) -> {error, 'MethodNotAllowed'}.

coap_observe(_EpID, _Prefix, _Suffix, _Request) -> {error, 'MethodNotAllowed'}.
coap_unobserve(_State) -> ok.
handle_info(_Message, _ObsReq, State) -> {noreply, State}.
coap_ack(_Ref, State) -> {ok, State}.

% fixture is my friend
empty_server_test_() ->
    {setup,
        fun() ->
            {ok, _} = application:ensure_all_started(ecoap),
            {ok, _} = ecoap:start_udp(?MODULE, [{port, 5683}], #{routes => []}),
            {ok, Client} = ecoap_client:open("127.0.0.1", 5683),
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
    ?_assertEqual(ok, ecoap_client:ping(Client)),
    % discovery
    ?_assertEqual({ok, {error, 'NotFound'}, #ecoap_content{}}, ecoap_client:get(Client, "/")),
    ?_assertEqual({ok, {error, 'NotFound'}, #ecoap_content{}}, ecoap_client:get(Client, "/.well-known")),
    ?_assertMatch({ok, {ok, 'Content'}, #ecoap_content{payload= <<"</.well-known/core>">>}}, ecoap_client:get(Client, "/.well-known/core")),
    % other methods
    ?_assertEqual({ok, {error, 'MethodNotAllowed'}, #ecoap_content{}}, ecoap_client:post(Client, "/.well-known/core", <<>>)),
    ?_assertEqual({ok, {error, 'MethodNotAllowed'}, #ecoap_content{}}, ecoap_client:put(Client, "/.well-known/core", <<>>)),
    ?_assertEqual({ok, {error, 'MethodNotAllowed'}, #ecoap_content{}}, ecoap_client:delete(Client, "/.well-known/core"))
    ].


unknown_handler_test_() ->
    {setup,
        fun() ->
            {ok, _} = application:ensure_all_started(ecoap),
            {ok, _} = ecoap:start_udp(?MODULE, [{port, 5683}], #{routes => [{[<<"unknown">>], unknown_module}]}),
            {ok, Client} = ecoap_client:open("127.0.0.1", 5683),
            Client
        end,
        fun(Client) ->
            application:stop(ecoap),
            ecoap_client:close(Client)
        end,
        fun unknown_handler/1}.

unknown_handler(Client) ->
    [
    ?_assertMatch({ok, {ok, 'Content'}, #ecoap_content{payload= <<"</.well-known/core>,</unknown>">>}}, ecoap_client:get(Client, "/.well-known/core")),
    ?_assertEqual({ok, {error,'MethodNotAllowed'}, #ecoap_content{}}, ecoap_client:get(Client, "/unknown"))
    ].

% end of file
