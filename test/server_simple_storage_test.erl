-module(server_simple_storage_test).
-behaviour(coap_resource).

-export([coap_discover/2, coap_get/5, coap_post/4, coap_put/4, coap_delete/4, 
        coap_observe/4, coap_unobserve/1, handle_notify/3, handle_info/3, coap_ack/2]).

-include_lib("eunit/include/eunit.hrl").
-define(NOT_IMPLEMENTED, <<"Not implemented">>).

% resource operations
coap_discover(Prefix, _Args) ->
    [{absolute, Prefix++Name, []} || Name <- mnesia:dirty_all_keys(resources)].

coap_get(_EpID, _Prefix, Name, _Query, _Request) ->
    case mnesia:dirty_read(resources, Name) of
        [{resources, Name, Content}] -> {ok, test_utils:from_record(Content)};
        [] -> {error, 'NotFound'}
    end.

coap_post(_EpId, _Prefix, _Suffix, _Request) ->
    {error, 'MethodNotAllowed', ?NOT_IMPLEMENTED}.

coap_put(_EpID, _Prefix, Name, Request) ->
    Content = coap_content:get_content(Request),
    mnesia:dirty_write(resources, {resources, Name, test_utils:to_record(Content)}).

coap_delete(_EpID, _Prefix, Name, _Request) ->
    mnesia:dirty_delete(resources, Name).

coap_observe(_EpID, _Prefix, _Name, _Request) -> 
    {error, 'MethodNotAllowed'}.

coap_unobserve(_State) -> 
    ok.

handle_notify(Info, _ObsReq, State) -> 
    {ok, Info, State}.

handle_info(_Info, _ObsReq, State) -> 
    {noreply, State}.

coap_ack(_Ref, State) -> 
	{ok, State}.

% fixture is my friend
server_simple_storage_test_() ->
    {setup,
        fun() ->
            ok = application:start(mnesia),
            {atomic, ok} = mnesia:create_table(resources, []),
            {ok, _} = application:ensure_all_started(ecoap),
            ecoap_registry:register_handler([{[<<"storage">>], ?MODULE, undefined}]),
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
    ?_assertEqual({ok, 'Deleted', coap_content:new()},
        ecoap_client:request(Client, 'DELETE', "coap://127.0.0.1/storage/one")),

    ?_assertEqual({error, 'NotFound'},
        ecoap_client:request(Client, 'GET', "coap://127.0.0.1/storage/one")),

    ?_assertEqual({error, 'MethodNotAllowed', #{payload=>?NOT_IMPLEMENTED, options=>#{}}},
        ecoap_client:request(Client, 'POST', "coap://127.0.0.1/storage/one", <<>>)),

    ?_assertEqual({ok, 'Created', coap_content:new()},
        ecoap_client:request(Client, 'PUT', "coap://127.0.0.1/storage/one",
        	<<"1">>, #{'ETag'=>[<<"1">>], 'If-None-Match'=>true})),

    ?_assertEqual({error, 'PreconditionFailed'},
        ecoap_client:request(Client, 'PUT', "coap://127.0.0.1/storage/one",
            <<"1">>, #{'ETag'=>[<<"1">>], 'If-None-Match'=>true})),

    ?_assertEqual({ok, 'Content', #{payload=> <<"1">>, options=>#{'ETag'=>[<<"1">>]}}},
        ecoap_client:request(Client, 'GET', "coap://127.0.0.1/storage/one")),

    ?_assertEqual({ok, 'Valid', #{payload=> <<>>, options=>#{'ETag'=>[<<"1">>]}}},
        ecoap_client:request(Client, 'GET', "coap://127.0.0.1/storage/one",
            <<>>, #{'ETag'=>[<<"1">>]})),

    ?_assertEqual({ok, 'Changed', coap_content:new()},
        ecoap_client:request(Client, 'PUT', "coap://127.0.0.1/storage/one", 
            <<"2">>, #{'ETag'=>[<<"2">>]})),

    ?_assertEqual({ok, 'Content', #{payload=> <<"2">>, options=>#{'ETag'=>[<<"2">>]}}},
        ecoap_client:request(Client, 'GET', "coap://127.0.0.1/storage/one")),

    ?_assertEqual({ok, 'Content', #{payload=> <<"2">>, options=>#{'ETag'=>[<<"2">>]}}},
        ecoap_client:request(Client, 'GET', "coap://127.0.0.1/storage/one",
            <<>>, #{'ETag'=>[<<"1">>]})),

    % observe existing resource when coap_observe is not implemented
    ?_assertEqual({ok, 'Content', #{payload=> <<"2">>, options=>#{'ETag'=>[<<"2">>]}}},
        ecoap_client:observe_and_wait_response(Client, "coap://127.0.0.1/storage/one")),

    ?_assertEqual({ok, 'Valid', #{payload=> <<>>, options=>#{'ETag'=>[<<"2">>]}}},
        ecoap_client:request(Client, 'GET', "coap://127.0.0.1/storage/one",
            <<>>, #{'ETag'=>[<<"1">>, <<"2">>]})),

    ?_assertEqual({ok, 'Deleted', coap_content:new()},
        ecoap_client:request(Client, 'DELETE', "coap://127.0.0.1/storage/one")),

    ?_assertEqual({error, 'NotFound'},
        ecoap_client:request(Client, 'GET', "coap://127.0.0.1/storage/one")),

    % observe non-existing resource when coap_observe is not implemented
    ?_assertEqual({error, 'NotFound'},
        ecoap_client:observe_and_wait_response(Client, "coap://127.0.0.1/storage/one"))
    ].

% end of file
