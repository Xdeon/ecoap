-module(server_observe_test).
-behaviour(ecoap_handler).

-export([coap_discover/1, coap_get/4, coap_post/4, coap_put/4, coap_delete/4, 
        coap_observe/4, coap_unobserve/1, handle_info/3, coap_ack/2]).

-include_lib("eunit/include/eunit.hrl").
-include_lib("src/ecoap_content.hrl").

% resource operations
coap_discover(Prefix) ->
    [{absolute, Prefix++Name, []} || Name <- mnesia:dirty_all_keys(resources)].

coap_get(_EpID, _Prefix, Name, _Request) ->
    case mnesia:dirty_read(resources, Name) of
        [{resources, Name, Content}] -> {ok, Content};
        [] -> {error, 'NotFound'}
    end.

coap_post(_EpId, _Prefix, _Suffix, _Request) ->
    {error, 'MethodNotAllowed'}.

coap_put(_EpID, Prefix, Name, Request) ->
    Content = ecoap_content:get_content(Request),
    mnesia:dirty_write(resources, {resources, Name, Content}),
    ecoap_handler:notify(Prefix++Name, Content),
    ok.

coap_delete(_EpID, _Prefix, Name, _Request) ->
    mnesia:dirty_delete(resources, Name).

coap_observe(_EpID, _Prefix, _Name, _Request) -> 
    {ok, undefined}.

coap_unobserve(_State) -> 
    ok.

handle_info({coap_notify, Content}, _ObsReq, State) ->
    {notify, Content, State};
handle_info(_Info, _ObsReq, State) ->
    {noreply, State}.

coap_ack(_Ref, State) ->
    {ok, State}.

% fixture is my friend
observe_test_() ->
    {setup,
        fun() ->
            ok = application:start(mnesia),
            {atomic, ok} = mnesia:create_table(resources, []),
            {ok, _} = application:ensure_all_started(ecoap),
            {ok, _} = ecoap:start_udp(?MODULE, [{port, 5683}], #{routes => [{[<<"text">>], ?MODULE}]}),
            {ok, Client} = ecoap_client:open("127.0.0.1", 5683),
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
    ?_assertEqual({ok, {error, 'NotFound'}, #ecoap_content{}},
        ecoap_client:observe_and_wait_response(Client, "/text")),
    ?_assertEqual({ok, {ok, 'Created'}, #ecoap_content{}},
    	begin 
    		#ecoap_content{payload=Payload, options=Options} = test_utils:text_resource([<<"1">>], 2000),
        	ecoap_client:put(Client, "/text", Payload, Options)
        end),
    ?_assertEqual(
    	{
	    	{ok, ref, Client, 0, {ok, {ok, 'Content'}, test_utils:text_resource([<<"1">>], 2000)}}, 
	    	{coap_notify, ref, Client, 1, {ok, {ok, 'Content'}, test_utils:text_resource([<<"2">>], 3000)}},
	    	{ok, {ok, 'Content'}, test_utils:text_resource([<<"2">>], 3000)}
    	}, 
    	begin 
    		#ecoap_content{payload=Payload, options=Options} = test_utils:text_resource([<<"2">>], 3000),
    		observe_and_modify(Client, "/text", Payload, Options)
    	end)
    ].

observe_and_modify(Client, Uri, Payload, Options) ->	
	{ok, _} = timer:apply_after(500, ecoap_client, put, [Client, Uri, Payload, Options]),
    {ok, Ref, Client, N1, {ok, Code, Content1}} = ecoap_client:observe_and_wait_response(Client, Uri),
	receive 
        {coap_notify, Ref, Client, N2, {ok, Code, Content2}} ->
            {
                {ok, ref, Client, N1, {ok, Code, Content1}},            % answer to the observe request
                {coap_notify, ref, Client, N2, {ok, Code, Content2}},   % notification
                ecoap_client:unobserve_and_wait_response(Client, Ref)   % answer to the cancellation
            }
	end.