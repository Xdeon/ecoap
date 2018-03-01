-module(ecoap_client_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("src/coap_message.hrl").
-include_lib("src/coap_content.hrl").

basic_test_() ->
    [{setup,
        fun() ->
            {ok, Pid} = ecoap_client:open(),
            Pid
        end,
        fun(Pid) ->
            ecoap_client:close(Pid)
        end,
        fun basic_sync/1},
    {setup,
        fun() ->
            {ok, Pid} = ecoap_client:open(),
            Pid
        end,
        fun(Pid) ->
            ecoap_client:close(Pid)
        end,
        fun basic_async/1}
    ].

basic_sync(Pid) ->
	[
        ?_assertEqual(ok, ecoap_client:ping(Pid, "coap://californium.eclipse.org:5683")),
		?_assertEqual({ok, {ok, 'Content'}, #coap_content{payload= <<"world">>, options=#{'Content-Format' => <<"text/plain">>}}}, 
			ecoap_client:get(Pid, "coap://coap.me:5683/hello")),
		?_assertEqual({ok, {error, 'InternalServerError'}, #coap_content{payload= <<"Oops: broken">>, options=#{'Content-Format' => <<"text/plain">>}}}, 
			ecoap_client:get(Pid, "coap://coap.me:5683/broken")),
        ?_assertEqual({ok, {ok, 'Created'}, #coap_content{options=#{'Location-Path' => [<<"large-create">>]}}},
            ecoap_client:post(Pid, "coap://coap.me:5683/large-create", <<"Test">>)),
        ?_assertEqual({ok, {ok, 'Changed'}, #coap_content{}}, 
            ecoap_client:put(Pid, "coap://coap.me:5683/large-update", <<"Test">>)),
        ?_assertEqual({ok, {ok, 'Deleted'}, #coap_content{payload= <<"DELETE OK">>, options=#{'Content-Format' => <<"text/plain">>}}}, 
            ecoap_client:delete(Pid, "coap://coap.me:5683/sink"))
	].

basic_async(Pid) ->
    [
        ?_assertEqual({ok, {ok, 'Content'}, #coap_content{payload= <<"world">>, options=#{'Content-Format' => <<"text/plain">>}}},
            await_response(Pid, ecoap_client:get_async(Pid, "coap://coap.me:5683/hello"))),
        ?_assertEqual({ok, {error, 'InternalServerError'}, #coap_content{payload= <<"Oops: broken">>, options=#{'Content-Format' => <<"text/plain">>}}}, 
            await_response(Pid, ecoap_client:get_async(Pid, "coap://coap.me:5683/broken"))),
        ?_assertEqual({ok, {ok, 'Created'}, #coap_content{options=#{'Location-Path' => [<<"large-create">>]}}},
            await_response(Pid, ecoap_client:post_async(Pid, "coap://coap.me:5683/large-create", <<"Test">>))),
        ?_assertEqual({ok, {ok, 'Changed'}, #coap_content{}}, 
            await_response(Pid, ecoap_client:put_async(Pid, "coap://coap.me:5683/large-update", <<"Test">>))),
        ?_assertEqual({ok, {ok, 'Deleted'}, #coap_content{payload= <<"DELETE OK">>, options=#{'Content-Format' => <<"text/plain">>}}}, 
            await_response(Pid, ecoap_client:delete_async(Pid, "coap://coap.me:5683/sink")))
    ].

await_response(Pid, {ok, Ref}) ->
    receive
        {coap_response, Ref, Pid, Response} -> Response
    end.

blockwise_test_() ->
    [
    {setup, 
        fun() -> 
            {ok, Pid} = ecoap_client:open(),
            Pid
        end,
        fun(Pid) ->
            ecoap_client:close(Pid)
        end,
        fun blockwise/1},
    {setup,
        fun() ->
            {ok, Server} = server_stub:start_link(5683),
            {ok, Client} = ecoap_client:open(),
            {Server, Client}
        end,
        fun({Server, Client}) ->
            ok = server_stub:close(Server),
            ok = ecoap_client:close(Client)
        end,
        fun error_while_observe_block/1}
    ].

blockwise(Pid) ->
    Response = ecoap_client:get(Pid, "coap://californium.eclipse.org:5683/large"),
    [
        ?_assertMatch({ok, {ok, 'Content'}, _}, Response), 
        ?_assertEqual(1280, begin {_, _, #coap_content{payload=Payload}} = Response, byte_size(Payload) end)
    ].

% verify that ecoap_client clean up its state in this case
error_while_observe_block({Server, Client}) ->
    _ = spawn_link(ecoap_client, observe, [Client, "coap://127.0.0.1:5683/test"]),
    ExpectReq = ecoap_request:request('CON', 'GET', #{'Uri-Path' => [<<"test">>], 'Observe' => 0}),
    timer:sleep(50),
    {match, BlockReqMsgId, BlockReqToken} = server_stub:expect_request(Server, ExpectReq),
    server_stub:send_response(Server, 
        #coap_message{type='ACK', code={ok, 'Content'}, id=BlockReqMsgId, token=BlockReqToken, options=#{'Observe' => 1, 'Block2' => {0, true, 64}}, payload=test_utils:large_binary(64, <<"A">>)}),
    timer:sleep(50),
    {match, BlockReqMsgId2, BlockReqToken2} = server_stub:expect_request(Server, coap_message:set_options(#{'Block2' => {1, false, 64}, 'Uri-Path' => [<<"test">>]}, ExpectReq)),
    server_stub:send_response(Server, 
        #coap_message{type='ACK', code={ok, 'Content'}, id=BlockReqMsgId2, token=BlockReqToken2, options=#{'Block2' => {1, true, 64}}, payload=test_utils:large_binary(64, <<"B">>)}),
    timer:sleep(50),
    {match, BlockReqMsgId3, BlockReqToken3} = server_stub:expect_request(Server, coap_message:set_options(#{'Block2' => {2, false, 64}, 'Uri-Path' => [<<"test">>]}, ExpectReq)),
    server_stub:send_response(Server, 
        #coap_message{type='ACK', code={ok, 'Content'}, id=BlockReqMsgId3, token=BlockReqToken3, options=#{'Block2' => {2, true, 64}}, payload=test_utils:large_binary(64, <<"C">>)}),
    timer:sleep(50),
    {match, BlockReqMsgId4, _} = server_stub:expect_request(Server, coap_message:set_options(#{'Block2' => {3, false, 64}, 'Uri-Path' => [<<"test">>]}, ExpectReq)),
    server_stub:send_response(Server, ecoap_request:rst(BlockReqMsgId4)),
    timer:sleep(50),
    ReqRefs = ecoap_client:get_reqrefs(Client),
    BlockRegs = ecoap_client:get_blockregs(Client),
    ObsRegs = ecoap_client:get_obsregs(Client),
    [
        ?_assertEqual(#{}, ReqRefs),
        ?_assertEqual(#{}, BlockRegs),
        ?_assertEqual(#{}, ObsRegs)
    ].

% TODO: more observe tests
