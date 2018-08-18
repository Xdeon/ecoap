-module(server_simple_storage_test).
-behaviour(ecoap_handler).

-export([coap_discover/1, coap_get/5, coap_post/4, coap_put/4, coap_delete/4]).

-include_lib("eunit/include/eunit.hrl").
-include_lib("src/coap_content.hrl").

-define(NOT_IMPLEMENTED, <<"Not implemented">>).

% resource operations
coap_discover(Prefix) ->
    [{absolute, Prefix++Name, []} || Name <- mnesia:dirty_all_keys(resources)].

coap_get(_EpID, _Prefix, Name, _Query, _Request) ->
    case mnesia:dirty_read(resources, Name) of
        [{resources, Name, Content}] -> {ok, Content};
        [] -> {error, 'NotFound'}
    end.

coap_post(_EpId, _Prefix, _Suffix, _Request) ->
    {error, 'MethodNotAllowed', ?NOT_IMPLEMENTED}.

coap_put(_EpID, _Prefix, Name, Request) ->
    Content = coap_content:get_content(Request),
    mnesia:dirty_write(resources, {resources, Name, Content}).

coap_delete(_EpID, _Prefix, Name, _Request) ->
    mnesia:dirty_delete(resources, Name).

% fixture is my friend
server_simple_storage_test_() ->
    {setup,
        fun() ->
            ok = application:start(mnesia),
            {atomic, ok} = mnesia:create_table(resources, []),
            {ok, _} = application:ensure_all_started(ecoap),
            {ok, _} = ecoap:start_udp(?MODULE, [], #{routes => [{[<<"storage">>, <<"*">>], ?MODULE}]}),
            {ok, Client} = ecoap_client:open("coap://127.0.0.1"),
            Client
        end,
        fun(Client) ->
            application:stop(ecoap),
            application:stop(mnesia),
            ecoap_client:close(Client)
        end,
        fun simple_storage_test/1}.

simple_storage_test(Client) ->
    [
    ?_assertEqual({ok, {ok, 'Deleted'}, #coap_content{}},
        ecoap_client:delete(Client, "/storage/one")),

    ?_assertEqual({ok, {error, 'NotFound'}, #coap_content{}},
        ecoap_client:get(Client, "/storage/one")),
    
    ?_assertEqual({ok, {error, 'MethodNotAllowed'}, #coap_content{payload=?NOT_IMPLEMENTED}},
        ecoap_client:post(Client, "/storage/one", <<>>)),

    ?_assertEqual({ok, {ok, 'Created'}, #coap_content{}},
        ecoap_client:put(Client, "/storage/one",
        	<<"1">>, #{'ETag'=>[<<"1">>], 'If-None-Match'=>true})),

    ?_assertEqual({ok, {error, 'PreconditionFailed'}, #coap_content{}},
        ecoap_client:put(Client, "/storage/one",
            <<"1">>, #{'ETag'=>[<<"1">>], 'If-None-Match'=>true})),

    ?_assertEqual({ok, {ok, 'Content'}, #coap_content{payload= <<"1">>, options=#{'ETag'=>[<<"1">>]}}},
        ecoap_client:get(Client, "/storage/one")),

    ?_assertEqual({ok, {ok, 'Valid'}, #coap_content{options=#{'ETag'=>[<<"1">>]}}},
        ecoap_client:get(Client, "/storage/one",
            #{'ETag'=>[<<"1">>]})),

    ?_assertEqual({ok, {ok, 'Changed'}, #coap_content{}},
        ecoap_client:put(Client, "/storage/one", 
            <<"2">>, #{'ETag'=>[<<"2">>]})),

    ?_assertEqual({ok, {ok, 'Content'}, #coap_content{payload= <<"2">>, options=#{'ETag'=>[<<"2">>]}}},
        ecoap_client:get(Client, "/storage/one")),

    ?_assertEqual({ok, {ok, 'Content'}, #coap_content{payload= <<"2">>, options=#{'ETag'=>[<<"2">>]}}},
        ecoap_client:get(Client, "/storage/one",
            #{'ETag'=>[<<"1">>]})),

    % observe existing resource when coap_observe is not implemented
    ?_assertEqual({ok, {ok, 'Content'}, #coap_content{payload= <<"2">>, options=#{'ETag'=>[<<"2">>]}}},
        ecoap_client:observe_and_wait_response(Client, "/storage/one")),

    ?_assertEqual({ok, {ok, 'Valid'}, #coap_content{options=#{'ETag'=>[<<"2">>]}}},
        ecoap_client:get(Client, "/storage/one",
            #{'ETag'=>[<<"1">>, <<"2">>]})),

    ?_assertEqual({ok, {ok, 'Deleted'}, #coap_content{}},
        ecoap_client:delete(Client, "/storage/one")),

    ?_assertEqual({ok, {error, 'NotFound'}, #coap_content{}},
        ecoap_client:get(Client, "/storage/one")),

    % observe non-existing resource when coap_observe is not implemented
    ?_assertEqual({ok, {error, 'NotFound'}, #coap_content{}},
        ecoap_client:observe_and_wait_response(Client, "/storage/one"))
    ].

% end of file
