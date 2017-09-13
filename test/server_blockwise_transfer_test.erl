-module(server_blockwise_transfer_test).
-behaviour(coap_resource).

-export([coap_discover/2, coap_get/5, coap_post/4, coap_put/4, coap_delete/4, 
        coap_observe/4, coap_unobserve/1, handle_notify/3, handle_info/3, coap_ack/2]).

-include_lib("eunit/include/eunit.hrl").
-include("ecoap.hrl").

coap_discover(Prefix, _Args) ->
    [{absolute, Prefix, []}].

% resource generator
coap_get(_EpID, [<<"text">>], [Size], _Query, _Request) ->
    {ok, test_utils:text_resource(binary_to_integer(Size))};
coap_get(_EpID, [<<"reflect">>], [], _Query, _Request) ->
    {error, 'NotFound'}.

coap_post(_EpID, _Prefix, [], Request) ->
	Content = ecoap_utils:get_content(Request),
    {ok, 'Content', Content}.

coap_put(_EpID, _Prefix, [], _Request) ->
    ok.

coap_delete(_EpID, _Prefix, _Suffix, _Request) -> {error, 'MethodNotAllowed'}.

coap_observe(_EpID, _Prefix, _Suffix, _Request) -> {error, 'MethodNotAllowed'}.
coap_unobserve(_State) -> ok.
handle_notify(Notification, _ObsReq, State) -> {ok, Notification, State}.
handle_info(_Message, _ObsReq, State) -> {noreply, State}.
coap_ack(_Ref, State) -> {ok, State}.


% fixture is my friend
blockwise_transfer_test_() ->
    {setup,
        fun() ->
            {ok, _} = application:ensure_all_started(ecoap),
            ecoap_registry:register_handler([{[<<"text">>], ?MODULE, undefined},
                                             {[<<"reflect">>], ?MODULE, undefined}]),
            {ok, Client} = ecoap_client:start_link(),
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
    ?_assertMatch({ok,'Content',#coap_content{format= <<"application/link-format">>, payload= <<"</reflect>,</text>">>}},
        ecoap_client:request(Client, 'GET', "coap://127.0.0.1/.well-known/core")),
    % resource access
    ?_assertEqual({ok,'Content',test_utils:text_resource(128)}, ecoap_client:request(Client, 'GET', "coap://127.0.0.1/text/128")),
    ?_assertEqual({ok,'Content',test_utils:text_resource(1024)}, ecoap_client:request(Client, 'GET', "coap://127.0.0.1/text/1024")),
    ?_assertEqual({ok,'Content',test_utils:text_resource(1984)}, ecoap_client:request(Client, 'GET', "coap://127.0.0.1/text/1984")),
    ?_assertEqual({ok,'Created',#coap_content{}}, ecoap_client:request(Client, 'PUT', "coap://127.0.0.1/reflect", test_utils:text_resource(128))),
    ?_assertEqual({ok,'Created',#coap_content{}}, ecoap_client:request(Client, 'PUT', "coap://127.0.0.1/reflect", test_utils:text_resource(1024))),
    ?_assertEqual({ok,'Created',#coap_content{}}, ecoap_client:request(Client, 'PUT', "coap://127.0.0.1/reflect", test_utils:text_resource(1984))),
    ?_assertEqual({ok,'Content',test_utils:text_resource(128)}, ecoap_client:request(Client, 'POST', "coap://127.0.0.1/reflect", test_utils:text_resource(128))),
    ?_assertEqual({ok,'Content',test_utils:text_resource(1024)}, ecoap_client:request(Client, 'POST', "coap://127.0.0.1/reflect", test_utils:text_resource(1024))),
    ?_assertEqual({ok,'Content',test_utils:text_resource(1984)}, ecoap_client:request(Client, 'POST', "coap://127.0.0.1/reflect", test_utils:text_resource(1984)))
    ].

% end of file