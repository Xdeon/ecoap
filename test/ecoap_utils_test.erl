-module(ecoap_utils_test).
-include_lib("eunit/include/eunit.hrl").
-include_lib("src/coap_message.hrl").
-include("ecoap.hrl").

request_compose_test_() ->
    [
        ?_assertEqual(#coap_message{type='CON', code='GET', id=0},
            ecoap_request:request('CON', 'GET')),
        ?_assertEqual(#coap_message{type='CON', code='PUT', id=0, payload= <<"payload">>},
            ecoap_request:request('CON', 'PUT', #{}, <<"payload">>)),
        ?_assertEqual(#coap_message{type='CON', code='PUT', id=0, options=#{'Uri-Path' => [<<"test">>]}, payload= <<"payload">>},
            ecoap_request:request('CON', 'PUT', #{'Uri-Path' => [<<"test">>]}, <<"payload">>))
    ].

response_compose_test_() ->
    Request = #coap_message{type='CON', code='GET', id=123, token= <<"Token">>, options=#{'Uri-Path' => [<<"test">>]}},
    Payload = <<"Payload">>,
    [
        ?_assertEqual(#coap_message{type='CON', code={error, 'NotFound'}, id=123, token= <<"Token">>},
            ecoap_request:response({error, 'NotFound'}, Request)),
        ?_assertEqual(#coap_message{type='CON', code={ok, 'Content'}, id=123, token= <<"Token">>, payload=Payload},
            ecoap_request:response({ok, 'Content'}, Payload, Request))
    ].

uri_test_() ->
    [
        ?_assertEqual({coap, undefined, {{192,168,0,1}, ?DEFAULT_COAP_PORT}, [], []}, ecoap_utils:decode_uri("coap://192.168.0.1")),
        % tests modified based on gen_coap coap_client
        ?_assertEqual({coap, <<"localhost">>, {{127,0,0,1},?DEFAULT_COAP_PORT},[], []}, ecoap_utils:decode_uri("coap://localhost")),
        ?_assertEqual({coap, <<"localhost">>, {{127,0,0,1},1234},[], []}, ecoap_utils:decode_uri("coap://localhost:1234")),
        ?_assertEqual({coap, <<"localhost">>, {{127,0,0,1},?DEFAULT_COAP_PORT},[], []}, ecoap_utils:decode_uri("coap://localhost/")),
        ?_assertEqual({coap, <<"localhost">>, {{127,0,0,1},1234},[], []}, ecoap_utils:decode_uri("coap://localhost:1234/")),
        ?_assertEqual({coaps, <<"localhost">>, {{127,0,0,1},?DEFAULT_COAPS_PORT},[], []}, ecoap_utils:decode_uri("coaps://localhost")),
        ?_assertEqual({coaps, <<"localhost">>, {{127,0,0,1},1234},[], []}, ecoap_utils:decode_uri("coaps://localhost:1234")),
        ?_assertEqual({coaps, <<"localhost">>, {{127,0,0,1},?DEFAULT_COAPS_PORT},[], []}, ecoap_utils:decode_uri("coaps://localhost/")),
        ?_assertEqual({coaps, <<"localhost">>, {{127,0,0,1},1234},[], []}, ecoap_utils:decode_uri("coaps://localhost:1234/")),
        ?_assertEqual({coap, <<"localhost">>, {{127,0,0,1},?DEFAULT_COAP_PORT},[<<"/">>], []}, ecoap_utils:decode_uri("coap://localhost/%2F")),
        % from RFC 7252, Section 6.3
        % the following three URIs are equivalent
        ?_assertEqual({coap, <<"localhost">>, {{127,0,0,1},5683},[<<"~sensors">>, <<"temp.xml">>], []},
            ecoap_utils:decode_uri("coap://localhost:5683/~sensors/temp.xml")),
        ?_assertEqual({coap, <<"localhost">>, {{127,0,0,1},?DEFAULT_COAP_PORT},[<<"~sensors">>, <<"temp.xml">>], []},
            ecoap_utils:decode_uri("coap://LOCALHOST/%7Esensors/temp.xml")),
        ?_assertEqual({coap, <<"localhost">>, {{127,0,0,1},?DEFAULT_COAP_PORT},[<<"~sensors">>, <<"temp.xml">>], []},
            ecoap_utils:decode_uri("coap://LOCALHOST/%7esensors/temp.xml")),
        % from RFC 7252, Appendix B
        ?_assertEqual({coap, <<"localhost">>, {{127,0,0,1},61616},[<<>>, <<"/">>, <<>>, <<>>], [<<"//">>,<<"?&">>]},
            ecoap_utils:decode_uri("coap://localhost:61616//%2F//?%2F%2F&?%26")),
        % unicode decode & encode test
        ?_assertEqual({coap, <<"localhost">>, {{127,0,0,1}, ?DEFAULT_COAP_PORT}, [<<"non-ascii-path-äöü"/utf8>>], [<<"non-ascii-query=äöü"/utf8>>]},
            ecoap_utils:decode_uri("coap://localhost:5683/non-ascii-path-%C3%A4%C3%B6%C3%BC?non-ascii-query=%C3%A4%C3%B6%C3%BC")),
        ?_assertEqual("coap://192.168.0.1:5683/non-ascii-path-%C3%A4%C3%B6%C3%BC?non-ascii-query=%C3%A4%C3%B6%C3%BC",
            ecoap_utils:encode_uri({coap, undefined, {{192,168,0,1}, ?DEFAULT_COAP_PORT}, [<<"non-ascii-path-äöü"/utf8>>], [<<"non-ascii-query=äöü"/utf8>>]})),
        ?_assertEqual("coap://example.com:5683/%E3%83%86%E3%82%B9%E3%83%88", 
            ecoap_utils:encode_uri({coap, <<"example.com">>, {{192,168,0,1}, ?DEFAULT_COAP_PORT}, [<<"テスト"/utf8>>], []}))
    ].

% TODO: add tests for large payload that triggers blockwise transfer
