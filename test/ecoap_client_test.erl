-module(ecoap_client_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("ecoap/include/coap_def.hrl").

basic_test_() ->
    {setup,
        fun() ->
            {ok, Pid} = ecoap_client:start_link(),
            Pid
        end,
        fun(Pid) ->
            ecoap_client:close(Pid)
        end,
        fun basic/1}.

basic(Pid) ->
	[
		?_assertEqual({ok, 'Content', #coap_content{max_age = undefined, format = <<"text/plain">>, payload = <<"world">>}}, 
			ecoap_client:request(Pid, 'GET', "coap://coap.me:5683/hello")),
		?_assertEqual({error, 'InternalServerError', #coap_content{max_age = undefined, format = <<"text/plain">>, payload = <<"Oops: broken">>}}, 
			ecoap_client:request(Pid, 'GET', "coap://coap.me:5683/broken"))
	].

blockwise_test_() ->
    [
    {setup, 
        fun() -> 
            {ok, Pid} = ecoap_client:start_link(),
            Pid
        end,
        fun(Pid) ->
            ecoap_client:close(Pid)
        end,
        fun blockwise/1},
    {setup,
        fun() ->
            {ok, Server} = server_stub:start_link(5683),
            {ok, Client} = ecoap_client:start_link(),
            {Server, Client}
        end,
        fun({Server, Client}) ->
            ok = server_stub:close(Server),
            ok = ecoap_client:close(Client)
        end,
        fun error_while_observe_block/1}
    ].

blockwise(Pid) ->
    Response = ecoap_client:request(Pid, 'GET', "coap://californium.eclipse.org:5683/large", <<>>, #{'Block2'=>{0, false, 512}}),
    [
        ?_assertMatch({ok, 'Content', #coap_content{}}, Response), 
        ?_assertEqual(1280, begin {_, _, #coap_content{payload=Payload}} = Response, byte_size(Payload) end)
    ].

% verify that ecoap_client clean up state in this case
error_while_observe_block({Server, Client}) ->
    _ = spawn_link(ecoap_client, observe, [Client, "coap://localhost:5683/test"]),
    ExpectReq = coap_message_utils:request('CON', 'GET', <<>>, #{'Uri-Path'=>[<<"test">>], 'Observe'=>0}),
    timer:sleep(50),
    {match, BlockReqMsgId, BlockReqToken} = server_stub:expect_request(Server, ExpectReq),
    server_stub:send_response(Server, 
        #coap_message{type='ACK', id=BlockReqMsgId, code={ok, 'Content'}, options=#{'Block2'=>{0, true, 64}, 'Observe'=>1}, token=BlockReqToken,
        payload= <<"|                 RESOURCE BLOCK NO. 1 OF 5                   |\n">>}),
    timer:sleep(50),
    {match, BlockReqMsgId2, BlockReqToken2} = server_stub:expect_request(Server, ExpectReq#coap_message{options=#{'Uri-Path'=>[<<"test">>], 'Block2'=>{1, false, 64}}}),
    server_stub:send_response(Server, 
        #coap_message{type='ACK', id=BlockReqMsgId2, code={ok, 'Content'}, options=#{'Block2'=>{1, true, 64}}, token=BlockReqToken2,
        payload= <<"|                 RESOURCE BLOCK NO. 2 OF 5                   |\n">>}),
    timer:sleep(50),
    {match, BlockReqMsgId3, BlockReqToken3} = server_stub:expect_request(Server, ExpectReq#coap_message{options=#{'Uri-Path'=>[<<"test">>], 'Block2'=>{2, false, 64}}}),
    server_stub:send_response(Server, 
        #coap_message{type='ACK', id=BlockReqMsgId3, code={ok, 'Content'}, options=#{'Block2'=>{2, true, 64}}, token=BlockReqToken3,
        payload= <<"|                 RESOURCE BLOCK NO. 3 OF 5                   |\n">>}),
    timer:sleep(50),
    {match, BlockReqMsgId4, _} = server_stub:expect_request(Server, ExpectReq#coap_message{options=#{'Uri-Path'=>[<<"test">>], 'Block2'=>{3, false, 64}}}),
    server_stub:send_response(Server, #coap_message{type='RST', id=BlockReqMsgId4}),
    timer:sleep(50),
    {state, _, ReqRefs, _} = sys:get_state(Client),
    [?_assertEqual(#{}, ReqRefs)].

% TODO: observe test
