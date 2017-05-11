-module(simple_storage_test).
-behaviour(coap_resource).

-export([coap_discover/2, coap_get/5, coap_post/4, coap_put/4, coap_delete/4, 
        coap_observe/4, coap_unobserve/1, coap_payload_adapter/2, handle_info/2, coap_ack/2]).

-include_lib("eunit/include/eunit.hrl").
-include_lib("ecoap_common/include/coap_def.hrl").

-define(NOT_IMPLEMENTED, <<"Not implemented">>).

% resource operations
coap_discover(Prefix, _Args) ->
    [{absolute, Prefix, []}].

coap_get(_EpId, _Prefix, [Name], _Query, _Request) ->
    case mnesia:dirty_read(resources, Name) of
        [{resources, Name, Resource}] -> {ok, Resource};
        [] -> {error, 'NotFound'}
    end.

coap_post(_EpId, _Prefix, _Suffix, _Request) ->
    {error, 'MethodNotAllowed', ?NOT_IMPLEMENTED}.

coap_put(_EpId, _Prefix, [Name], Request) ->    
    Content = coap_utils:get_content(Request),
    mnesia:dirty_write(resources, {resources, Name, Content}).

coap_delete(_EpId, _Prefix, [Name], _Request) ->
    mnesia:dirty_delete(resources, Name).

coap_observe(_EpId, _Prefix, _Suffix, _Request) -> {error, 'MethodNotAllowed'}.
coap_unobserve(_State) -> ok.
coap_payload_adapter(Content, _Accept) -> {ok, Content}.
handle_info(_Message, State) -> {noreply, State}.
coap_ack(_Ref, State) -> {ok, State}.


% fixture is my friend
simple_storage_test_() ->
    {setup,
        fun() ->
            ok = application:start(mnesia),
            {atomic, ok} = mnesia:create_table(resources, []),
            {ok, _} = application:ensure_all_started(ecoap),
            ecoap_registry:register_handler([<<"storage">>], ?MODULE, undefined),
            {ok, Client} = ecoap_client:start_link(),
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
    ?_assertEqual({ok, 'Deleted', #coap_content{}},
        ecoap_client:request(Client, 'DELETE', "coap://127.0.0.1/storage/one")),

    ?_assertEqual({error, 'NotFound'},
        ecoap_client:request(Client, 'GET', "coap://127.0.0.1/storage/one")),

    ?_assertEqual({error, 'MethodNotAllowed', #coap_content{payload=?NOT_IMPLEMENTED}},
        ecoap_client:request(Client, 'POST', "coap://127.0.0.1/storage/one", <<>>)),

    ?_assertEqual({ok, 'Created', #coap_content{}},
        ecoap_client:request(Client, 'PUT', "coap://127.0.0.1/storage/one",
            #coap_content{etag= <<"1">>, payload= <<"1">>}, [{'If-None-Match', true}])),

    ?_assertEqual({error, 'PreconditionFailed'},
        ecoap_client:request(Client, 'PUT', "coap://127.0.0.1/storage/one",
            <<"1">>, [{'ETag', [<<"1">>]}, {'If-None-Match', true}])),

    ?_assertEqual({ok, 'Content', #coap_content{etag= <<"1">>, payload= <<"1">>}},
        ecoap_client:request(Client, 'GET', "coap://127.0.0.1/storage/one")),

    ?_assertEqual({ok, 'Valid', #coap_content{etag= <<"1">>}},
        ecoap_client:request(Client, 'GET', "coap://127.0.0.1/storage/one",
            #coap_content{etag= <<"1">>})),

    ?_assertEqual({ok, 'Changed', #coap_content{}},
        ecoap_client:request(Client, 'PUT', "coap://127.0.0.1/storage/one", 
            <<"2">>, [{'ETag', [<<"2">>]}])),

    ?_assertEqual({ok, 'Content', #coap_content{etag= <<"2">>, payload= <<"2">>}},
        ecoap_client:request(Client, 'GET', "coap://127.0.0.1/storage/one")),

    ?_assertEqual({ok, 'Content', #coap_content{etag= <<"2">>, payload= <<"2">>}},
        ecoap_client:request(Client, 'GET', "coap://127.0.0.1/storage/one",
            <<>>, [{'ETag', [<<"1">>]}])),

    % observe existing resource when coap_observe is not implemented
    ?_assertEqual({ok, 'Content', #coap_content{etag= <<"2">>, payload= <<"2">>}},
        ecoap_client:observe(Client, "coap://127.0.0.1/storage/one")),

    ?_assertEqual({ok, 'Valid', #coap_content{etag= <<"2">>}},
        ecoap_client:request(Client, 'GET', "coap://127.0.0.1/storage/one",
            <<>>, [{'ETag', [<<"1">>, <<"2">>]}])),

    ?_assertEqual({ok, 'Deleted', #coap_content{}},
        ecoap_client:request(Client, 'DELETE', "coap://127.0.0.1/storage/one")),

    ?_assertEqual({error, 'NotFound'},
        ecoap_client:request(Client, 'GET', "coap://127.0.0.1/storage/one")),

    % observe non-existing resource when coap_observe is not implemented
    ?_assertEqual({error, 'NotFound'},
        ecoap_client:observe(Client, "coap://127.0.0.1/storage/one"))
    ].

% end of file
