-module(server_blockwise_transfer_test).
-behaviour(ecoap_handler).

-export([coap_discover/1, coap_get/4, coap_post/4, coap_put/4]).

-include_lib("eunit/include/eunit.hrl").
-include_lib("src/coap_content.hrl").

coap_discover(Prefix) ->
    [{absolute, Prefix, []}].

% resource generator
coap_get(_EpID, [<<"text">>], [Size], _Request) ->
    {ok, test_utils:text_resource(binary_to_integer(Size))};
coap_get(_EpID, [<<"reflect">>], [], _Request) ->
    {error, 'NotFound'}.

coap_post(_EpID, _Prefix, [], Request) ->
    {ok, 'Content', coap_content:get_content(Request)}.

coap_put(_EpID, _Prefix, [], _Request) ->
    ok.

% fixture is my friend
blockwise_transfer_test_() ->
    {setup,
        fun() ->
            {ok, _} = application:ensure_all_started(ecoap),
            {ok, _} = ecoap:start_udp(?MODULE, #{routes => [{[<<"text">>, <<"*">>], ?MODULE}, {[<<"reflect">>], ?MODULE}]}),
            {ok, Client} = ecoap_client:open("coap://127.0.0.1"),
            Client
        end,
        fun(Client) ->
            application:stop(ecoap),
            ecoap_client:close(Client)
        end,
        fun blockwise_transfer/1}.

blockwise_transfer(Client) ->
    [
    % discovery
    ?_assertMatch({ok, {ok, 'Content'}, 
        #coap_content{payload= <<"</reflect>,</text>">>, options=#{'Content-Format':= <<"application/link-format">>}}}, 
            ecoap_client:get(Client, "/.well-known/core")),
    % resource access
    ?_assertEqual({ok, {ok, 'Content'}, test_utils:text_resource(128)}, ecoap_client:get(Client, "/text/128")),
    ?_assertEqual({ok, {ok, 'Content'}, test_utils:text_resource(1024)}, ecoap_client:get(Client, "/text/1024")),
    ?_assertEqual({ok, {ok, 'Content'}, test_utils:text_resource(1984)}, ecoap_client:get(Client, "/text/1984")),
    ?_assertEqual({ok, {ok, 'Created'}, #coap_content{}}, 
        begin 
            #coap_content{payload=Payload, options=Options} = test_utils:text_resource(128),
            ecoap_client:put(Client, "/reflect", Payload, Options) 
        end),
    ?_assertEqual({ok, {ok, 'Created'}, #coap_content{}}, 
        begin
            #coap_content{payload=Payload, options=Options} = test_utils:text_resource(1024),
            ecoap_client:put(Client, "/reflect", Payload, Options)
        end),
    ?_assertEqual({ok, {ok, 'Created'}, #coap_content{}}, 
        begin
            #coap_content{payload=Payload, options=Options} =  test_utils:text_resource(1984),
            ecoap_client:put(Client, "/reflect", Payload, Options)
        end),
    ?_assertEqual({ok, {ok, 'Content'}, test_utils:text_resource(128)}, 
        begin 
            #coap_content{payload=Payload, options=Options} = test_utils:text_resource(128),
            ecoap_client:post(Client, "/reflect", Payload, Options)
        end),
    ?_assertEqual({ok, {ok, 'Content'}, test_utils:text_resource(1024)}, 
        begin 
            #coap_content{payload=Payload, options=Options} = test_utils:text_resource(1024),
            ecoap_client:post(Client, "/reflect", Payload, Options)
        end),
    ?_assertEqual({ok, {ok, 'Content'}, test_utils:text_resource(1984)}, 
        begin
            #coap_content{payload=Payload, options=Options} = test_utils:text_resource(1984),
            ecoap_client:post(Client, "/reflect", Payload, Options)
        end)
    ].

% end of file