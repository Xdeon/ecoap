-module(empty_server_test).
-behaviour(coap_resource).

-export([coap_discover/2, coap_get/5, coap_post/4, coap_put/4, coap_delete/3, coap_observe/4, coap_unobserve/1, handle_info/2, coap_ack/2]).

-include_lib("eunit/include/eunit.hrl").
-include_lib("ecoap/include/coap_def.hrl").

coap_discover(_Prefix, _Args) -> [].

coap_get(_EpID, _Prefix, _Suffix, _Query, _Accept) -> {error, 'MethodNotAllowed'}.
coap_post(_EpID, _Prefix, _Suffix, _Content) -> {error, 'MethodNotAllowed'}.
coap_put(_EpID, _Prefix, _Suffix, _Content) -> {error, 'MethodNotAllowed'}.
coap_delete(_EpID, _Prefix, _Suffix) -> {error, 'MethodNotAllowed'}.

coap_observe(_EpID, _Prefix, _Suffix, _Ack) -> {error, 'MethodNotAllowed'}.
coap_unobserve(_State) -> ok.
handle_info(_Message, State) -> {noreply, State}.
coap_ack(_Ref, State) -> {ok, State}.

% fixture is my friend
empty_server_test_() ->
    {setup,
        fun() ->
            {ok, _} = application:ensure_all_started(ecoap)
        end,
        fun(_State) ->
            application:stop(ecoap)
        end,
        fun empty_server/1}.

empty_server(_State) ->
    [
    % provoked reset
    ?_assertEqual(ok, ecoap_simple_client:ping("coap://127.0.0.1")),
    % discovery
    ?_assertEqual({error, 'NotFound'}, ecoap_simple_client:request('GET', "coap://127.0.0.1")),
    ?_assertEqual({error, 'NotFound'}, ecoap_simple_client:request('GET', "coap://127.0.0.1/.well-known")),
    ?_assertMatch({ok, 'Content', #coap_content{payload= <<>>}}, ecoap_simple_client:request('GET', "coap://127.0.0.1/.well-known/core")),
    % other methods
    ?_assertEqual({error,'MethodNotAllowed'}, ecoap_simple_client:request('POST', "coap://127.0.0.1/.well-known/core")),
    ?_assertEqual({error,'MethodNotAllowed'}, ecoap_simple_client:request('PUT', "coap://127.0.0.1/.well-known/core")),
    ?_assertEqual({error,'MethodNotAllowed'}, ecoap_simple_client:request('DELETE', "coap://127.0.0.1/.well-known/core"))
    ].


unknown_handler_test_() ->
    {setup,
        fun() ->
            {ok, _} = application:ensure_all_started(ecoap),
            ecoap_registry:register_handler([<<"unknown">>], unknown_module, undefined)
        end,
        fun(_State) ->
            application:stop(ecoap)
        end,
        fun unknown_handler/1}.

unknown_handler(_State) ->
    [
    % provoked reset
    ?_assertMatch({ok, 'Content', #coap_content{payload= <<>>}}, ecoap_simple_client:request('GET', "coap://127.0.0.1/.well-known/core")),
    ?_assertEqual({error,'InternalServerError'}, ecoap_simple_client:request('GET', "coap://127.0.0.1/unknown"))
    ].

% end of file