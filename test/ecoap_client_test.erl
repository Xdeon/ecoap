-module(ecoap_client_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("src/ecoap_message.hrl").
-include_lib("src/ecoap_content.hrl").

basic_test_() ->
    [{setup,
        fun() ->
            {ok, Pid} = ecoap_client:open("127.0.0.1", 50234),
            Pid
        end,
        fun(Pid) ->
            ecoap_client:close(Pid)
        end,
        fun unresponsive_endpoint/1},
    {setup,
        fun() ->
            {ok, Pid} = ecoap_client:open("coap.me", 5683),
            Pid
        end,
        fun(Pid) ->
            ecoap_client:close(Pid)
        end,
        fun basic_sync/1},
    {setup,
        fun() ->
            {ok, Pid} = ecoap_client:open("coap.me", 5683),
            Pid
        end,
        fun(Pid) ->
            ecoap_client:close(Pid)
        end,
        fun basic_async/1}
    ].

unresponsive_endpoint(Pid) ->
    [
        ?_assertMatch({'EXIT', _}, catch ecoap_client:ping(Pid, 1000)),
        ?_assertMatch({'EXIT', _}, catch ecoap_client:get(Pid, "/made_up", #{}, 1000)),
        ?_assertMatch({'EXIT', _}, catch ecoap_client:put(Pid, "/made_up", <<>>, #{}, 1000)),
        ?_assertMatch({'EXIT', _}, catch ecoap_client:post(Pid, "/made_up", <<>>, #{}, 1000)),
        ?_assertMatch({'EXIT', _}, catch ecoap_client:delete(Pid, "/made_up", #{}, 1000))
    ].

basic_sync(Pid) ->
	[
        ?_assertEqual(ok, ecoap_client:ping(Pid)),
		?_assertEqual({ok, {ok, 'Content'}, #ecoap_content{payload= <<"world">>, options=#{'Content-Format' => <<"text/plain">>}}}, 
			ecoap_client:get(Pid, "/hello")),
		?_assertEqual({ok, {error, 'InternalServerError'}, #ecoap_content{payload= <<"Oops: broken">>, options=#{'Content-Format' => <<"text/plain">>}}}, 
			ecoap_client:get(Pid, "/broken")),
        ?_assertEqual({ok, {ok, 'Created'}, #ecoap_content{options=#{'Location-Path' => [<<"large-create">>]}}},
            ecoap_client:post(Pid, "/large-create", <<"Test">>)),
        ?_assertEqual({ok, {ok, 'Changed'}, #ecoap_content{}}, 
            ecoap_client:put(Pid, "/large-update", <<"Test">>)),
        ?_assertEqual({ok, {ok, 'Deleted'}, #ecoap_content{payload= <<"DELETE OK">>, options=#{'Content-Format' => <<"text/plain">>}}}, 
            ecoap_client:delete(Pid, "/sink"))
	].

basic_async(Pid) ->
    [
        ?_assertEqual({ok, {ok, 'Content'}, #ecoap_content{payload= <<"world">>, options=#{'Content-Format' => <<"text/plain">>}}},
            await_response(Pid, ecoap_client:get_async(Pid, "/hello"))),
        ?_assertEqual({ok, {error, 'InternalServerError'}, #ecoap_content{payload= <<"Oops: broken">>, options=#{'Content-Format' => <<"text/plain">>}}}, 
            await_response(Pid, ecoap_client:get_async(Pid, "/broken"))),
        ?_assertEqual({ok, {ok, 'Created'}, #ecoap_content{options=#{'Location-Path' => [<<"large-create">>]}}},
            await_response(Pid, ecoap_client:post_async(Pid, "/large-create", <<"Test">>))),
        ?_assertEqual({ok, {ok, 'Changed'}, #ecoap_content{}}, 
            await_response(Pid, ecoap_client:put_async(Pid, "/large-update", <<"Test">>))),
        ?_assertEqual({ok, {ok, 'Deleted'}, #ecoap_content{payload= <<"DELETE OK">>, options=#{'Content-Format' => <<"text/plain">>}}}, 
            await_response(Pid, ecoap_client:delete_async(Pid, "/sink")))
    ].

await_response(Pid, {ok, Ref}) ->
    receive
        {coap_response, Ref, Pid, Response} -> Response
    end.

blockwise_test_() ->
    [
    {setup, 
        fun() -> 
            {ok, Pid} = ecoap_client:open("californium.eclipse.org", 5683),
            Pid
        end,
        fun(Pid) ->
            ecoap_client:close(Pid)
        end,
        fun blockwise/1},
    {setup,
        fun() ->
            {ok, Server} = server_stub:start_link(5683),
            {ok, Client} = ecoap_client:open("127.0.0.1", 5683),
            {Server, Client}
        end,
        fun({Server, Client}) ->
            ok = server_stub:close(Server),
            ok = ecoap_client:close(Client)
        end,
        fun error_while_observe_block/1}
    ].

blockwise(Pid) ->
    Response = ecoap_client:get(Pid, "/large"),
    [
        ?_assertMatch({ok, {ok, 'Content'}, _}, Response), 
        ?_assertEqual(1280, begin {_, _, #ecoap_content{payload=Payload}} = Response, byte_size(Payload) end)
    ].

% verify that ecoap_client clean up its state in this case
error_while_observe_block({Server, Client}) ->
    _ = ecoap_client:observe(Client, "/test"),
    ExpectReq = ecoap_request:request('CON', 'GET', #{'Uri-Path' => [<<"test">>], 'Observe' => 0}),
    timer:sleep(50),
    {match, BlockReqMsgId, BlockReqToken} = server_stub:expect_request(Server, ExpectReq),
    server_stub:send_response(Server, 
        #coap_message{type='ACK', code={ok, 'Content'}, id=BlockReqMsgId, token=BlockReqToken, options=#{'Observe' => 1, 'Block2' => {0, true, 64}}, payload=binary:copy(<<"A">>, 64)}),
    timer:sleep(50),
    {match, BlockReqMsgId2, BlockReqToken2} = server_stub:expect_request(Server, ecoap_message:set_options(#{'Block2' => {1, false, 64}, 'Uri-Path' => [<<"test">>]}, ExpectReq)),
    server_stub:send_response(Server, 
        #coap_message{type='ACK', code={ok, 'Content'}, id=BlockReqMsgId2, token=BlockReqToken2, options=#{'Block2' => {1, true, 64}}, payload=binary:copy(<<"B">>, 64)}),
    timer:sleep(50),
    {match, BlockReqMsgId3, BlockReqToken3} = server_stub:expect_request(Server, ecoap_message:set_options(#{'Block2' => {2, false, 64}, 'Uri-Path' => [<<"test">>]}, ExpectReq)),
    server_stub:send_response(Server, 
        #coap_message{type='ACK', code={ok, 'Content'}, id=BlockReqMsgId3, token=BlockReqToken3, options=#{'Block2' => {2, true, 64}}, payload=binary:copy(<<"C">>, 64)}),
    timer:sleep(50),
    {match, BlockReqMsgId4, _} = server_stub:expect_request(Server, ecoap_message:set_options(#{'Block2' => {3, false, 64}, 'Uri-Path' => [<<"test">>]}, ExpectReq)),
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

%% TODO: more observe tests
