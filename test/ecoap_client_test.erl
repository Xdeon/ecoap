-module(ecoap_client_test).

-include_lib("eunit/include/eunit.hrl").

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
		?_assertEqual({ok, 'Content', <<"world">>, #{'Content-Format' => <<"text/plain">>}}, 
			ecoap_client:request(Pid, 'GET', "coap://coap.me:5683/hello")),
		?_assertEqual({error, 'InternalServerError', <<"Oops: broken">>, #{'Content-Format' => <<"text/plain">>}}, 
			ecoap_client:request(Pid, 'GET', "coap://coap.me:5683/broken")),
        ?_assertEqual({ok, 'Created', <<>>, #{'Location-Path' => [<<"large-create">>]}},
            ecoap_client:request(Pid, 'POST', "coap://coap.me:5683/large-create", <<"Test">>)),
        ?_assertEqual({ok, 'Changed', <<>>, #{}}, 
            ecoap_client:request(Pid, 'PUT', "coap://coap.me:5683/large-update", <<"Test">>)),
        ?_assertEqual({ok, 'Deleted', <<"DELETE OK">>, #{'Content-Format' => <<"text/plain">>}}, 
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
        ?_assertMatch({ok, 'Content', _, _}, Response), 
        ?_assertEqual(1700, begin {_, _, Payload, _} = Response, byte_size(Payload) end)
    ].

% verify that ecoap_client clean up its state in this case
error_while_observe_block({Server, Client}) ->
    _ = spawn_link(ecoap_client, observe, [Client, "coap://127.0.0.1:5683/test"]),
    ExpectReq = ecoap_utils:request('CON', 'GET', <<>>, #{'Uri-Path' => [<<"test">>], 'Observe' => 0}),
    timer:sleep(50),
    {match, BlockReqMsgId, BlockReqToken} = server_stub:expect_request(Server, ExpectReq),
    server_stub:send_response(Server, 
        #{type=>'ACK', id=>BlockReqMsgId, code=>{ok, 'Content'}, options=>#{'Observe' => 1, 'Block2' => {0, true, 64}}, token=>BlockReqToken,
        payload=>test_utils:large_binary(64, <<"A">>)}),
    timer:sleep(50),
    {match, BlockReqMsgId2, BlockReqToken2} = server_stub:expect_request(Server, ExpectReq#{options:=#{'Block2' => {1, false, 64}, 'Uri-Path' => [<<"test">>]}}),
    server_stub:send_response(Server, 
        #{type=>'ACK', id=>BlockReqMsgId2, code=>{ok, 'Content'}, options=>#{'Block2' => {1, true, 64}}, token=>BlockReqToken2,
        payload=>test_utils:large_binary(64, <<"B">>)}),
    timer:sleep(50),
    {match, BlockReqMsgId3, BlockReqToken3} = server_stub:expect_request(Server, ExpectReq#{options:=#{'Block2' => {2, false, 64}, 'Uri-Path' => [<<"test">>]}}),
    server_stub:send_response(Server, 
        #{type=>'ACK', id=>BlockReqMsgId3, code=>{ok, 'Content'}, options=>#{'Block2' => {2, true, 64}}, token=>BlockReqToken3,
        payload=>test_utils:large_binary(64, <<"C">>)}),
    timer:sleep(50),
    {match, BlockReqMsgId4, _} = server_stub:expect_request(Server, ExpectReq#{options:=#{'Block2' => {3, false, 64}, 'Uri-Path' => [<<"test">>]}}),
    server_stub:send_response(Server, ecoap_utils:rst(BlockReqMsgId4)),
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
