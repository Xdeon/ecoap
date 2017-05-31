-module(ecoap_client_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("ecoap_common/include/coap_def.hrl").

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
        ?_assertEqual(ok, ecoap_client:ping(Pid, "coap://coap.me:5683")),
		?_assertEqual({ok, 'Content', #coap_content{format = <<"text/plain">>, payload = <<"world">>}}, 
			ecoap_client:request(Pid, 'GET', "coap://coap.me:5683/hello")),
		?_assertEqual({error, 'InternalServerError', #coap_content{format = <<"text/plain">>, payload = <<"Oops: broken">>}}, 
			ecoap_client:request(Pid, 'GET', "coap://coap.me:5683/broken")),
        ?_assertEqual({ok, 'Created', #coap_content{options=[{'Location-Path', [<<"large-create">>]}]}},
            ecoap_client:request(Pid, 'POST', "coap://coap.me:5683/large-create", <<"Test">>)),
        ?_assertEqual({ok, 'Changed', #coap_content{}}, 
            ecoap_client:request(Pid, 'PUT', "coap://coap.me:5683/large-update", <<"Test">>)),
        ?_assertEqual({ok, 'Deleted', #coap_content{format = <<"text/plain">>, payload = <<"DELETE OK">>}}, 
            ecoap_client:request(Pid, 'DELETE', "coap://coap.me:5683/sink"))
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
    Response = ecoap_client:request(Pid, 'GET', "coap://coap.me:5683/large"),
    [
        ?_assertMatch({ok, 'Content', #coap_content{}}, Response), 
        ?_assertEqual(1700, begin {_, _, #coap_content{payload=Payload}} = Response, byte_size(Payload) end)
    ].

% verify that ecoap_client clean up its state in this case
error_while_observe_block({Server, Client}) ->
    _ = spawn_link(ecoap_client, observe, [Client, "coap://localhost:5683/test"]),
    ExpectReq = coap_utils:request('CON', 'GET', <<>>, [{'Uri-Path', [<<"test">>]}, {'Observe', 0}]),
    timer:sleep(50),
    {match, BlockReqMsgId, BlockReqToken} = server_stub:expect_request(Server, ExpectReq),
    server_stub:send_response(Server, 
        #coap_message{type='ACK', id=BlockReqMsgId, code={ok, 'Content'}, options=[{'Observe', 1}, {'Block2', {0, true, 64}}], token=BlockReqToken,
        payload= <<"|                 RESOURCE BLOCK NO. 1 OF 5                   |\n">>}),
    timer:sleep(50),
    {match, BlockReqMsgId2, BlockReqToken2} = server_stub:expect_request(Server, ExpectReq#coap_message{options=[{'Block2', {1, false, 64}}, {'Uri-Path', [<<"test">>]}]}),
    server_stub:send_response(Server, 
        #coap_message{type='ACK', id=BlockReqMsgId2, code={ok, 'Content'}, options=[{'Block2', {1, true, 64}}], token=BlockReqToken2,
        payload= <<"|                 RESOURCE BLOCK NO. 2 OF 5                   |\n">>}),
    timer:sleep(50),
    {match, BlockReqMsgId3, BlockReqToken3} = server_stub:expect_request(Server, ExpectReq#coap_message{options=[{'Block2', {2, false, 64}}, {'Uri-Path', [<<"test">>]}]}),
    server_stub:send_response(Server, 
        #coap_message{type='ACK', id=BlockReqMsgId3, code={ok, 'Content'}, options=[{'Block2', {2, true, 64}}], token=BlockReqToken3,
        payload= <<"|                 RESOURCE BLOCK NO. 3 OF 5                   |\n">>}),
    timer:sleep(50),
    {match, BlockReqMsgId4, _} = server_stub:expect_request(Server, ExpectReq#coap_message{options=[{'Block2', {3, false, 64}}, {'Uri-Path', [<<"test">>]}]}),
    server_stub:send_response(Server, #coap_message{type='RST', id=BlockReqMsgId4}),
    timer:sleep(50),
    ReqRefs = ecoap_client:get_reqrefs(Client),
    BlockRefs = ecoap_client:get_blockrefs(Client),
    ObsRegs = ecoap_client:get_obsregs(Client),
    [
        ?_assertEqual(#{}, ReqRefs),
        ?_assertEqual(#{}, BlockRefs),
        ?_assertEqual(#{}, ObsRegs)
    ].

% TODO: more observe tests
