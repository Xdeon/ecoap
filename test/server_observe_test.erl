-module(server_observe_test).
-behaviour(coap_resource).

-export([coap_discover/2, coap_get/5, coap_post/4, coap_put/4, coap_delete/4, 
        coap_observe/4, coap_unobserve/1, handle_notify/3, handle_info/3, coap_ack/2]).

-include_lib("eunit/include/eunit.hrl").
-include_lib("ecoap_common/include/coap_def.hrl").

% resource generator
coap_discover(Prefix, _Args) ->
    [{absolute, Prefix, []}].

coap_get(_EpID, _Prefix, [], _Query, _Request) ->
    case mnesia:dirty_read(resources, []) of
        [{resources, [], Resource}] -> {ok, Resource};
        [] -> {error, 'NotFound'}
    end.

coap_post(_EpID, _Prefix, _Suffix, _Request) ->
    {error, 'MethodNotAllowed'}.

coap_put(_EpID, Prefix, [], Request) ->
	Content = coap_utils:get_content(Request),
    mnesia:dirty_write(resources, {resources, [], Content}),
    ecoap_handler:notify(Prefix, Content),
    ok.

coap_delete(_EpID, _Prefix, _Suffix, _Request) ->
    {error, 'MethodNotAllowed'}.

coap_observe(_EpID, _Prefix, [], _Request) -> {ok, undefined}.
coap_unobserve(_State) -> ok.
handle_notify(Notification, _ObsReq, State) -> {ok, Notification, State}.
handle_info(_Message, _ObsReq, State) -> {noreply, State}.
coap_ack(_Ref, State) -> {ok, State}.


% fixture is my friend
observe_test_() ->
    {setup,
        fun() ->
            ok = application:start(mnesia),
            {atomic, ok} = mnesia:create_table(resources, []),
            {ok, _} = application:ensure_all_started(ecoap),
            ecoap_registry:register_handler([<<"text">>], ?MODULE, undefined),
            {ok, Client} = ecoap_client:start_link(),
            Client
        end,
        fun(Client) ->
            application:stop(ecoap),
            application:stop(mnesia),
            ecoap_client:close(Client)
        end,
        fun observe_test/1}.

observe_test(Client) ->
    [
    ?_assertEqual({error, 'NotFound'},
        ecoap_client:observe(Client, "coap://127.0.0.1/text")),
    ?_assertEqual({ok, 'Created', #coap_content{}},
        ecoap_client:request(Client, 'PUT', "coap://127.0.0.1/text", test_utils:text_resource(<<"1">>, 2000))),
    ?_assertEqual(
    	{
	    	{ok, ref, Client, 0, 'Content', test_utils:text_resource(<<"1">>, 2000)}, 
	    	{coap_notify, ref, Client, 1, {ok, 'Content', test_utils:text_resource(<<"2">>, 3000)}},
	    	{ok, 'Content', test_utils:text_resource(<<"2">>, 3000)}
    	}, 
    	observe_and_modify(Client, "coap://127.0.0.1/text", test_utils:text_resource(<<"2">>, 3000)))
    ].

observe_and_modify(Client, Uri, Resource) ->	
	{ok, _} = timer:apply_after(500, ecoap_client, request, [Client, 'PUT', Uri, Resource]),
	{ok, Ref, Client, N1, Code, Content1} = ecoap_client:observe(Client, Uri),
	receive 
		{coap_notify, Ref, Client, N2, {ok, Code, Content2}} ->
			{
				{ok, ref, Client, N1, Code, Content1},
				{coap_notify, ref, Client, N2, {ok, Code, Content2}},
				ecoap_client:unobserve(Client, Ref)
			}
	end.

