-module(ecoap_utils_test).
-include_lib("eunit/include/eunit.hrl").
-include("ecoap.hrl").

request_compose_test_() ->
    Default = coap_message:new(),
    [
        ?_assertEqual(Default#{type:='CON', code:='GET'},
            ecoap_utils:request('CON', 'GET')),
        ?_assertEqual(Default#{type:='CON', code:='PUT', payload:= <<"payload">>}, 
            ecoap_utils:request('CON', 'PUT', <<"payload">>)),
        ?_assertEqual(Default#{type:='CON', code:='PUT', options:=#{'Uri-Path' => [<<"test">>]}, payload:= <<"payload">>}, 
            ecoap_utils:request('CON', 'PUT', <<"payload">>, #{'Uri-Path' => [<<"test">>]}))
    ].

response_compose_test_() ->
    Request = #{type=>'CON', id=>123, code=>'GET', 
                    token=> <<"Token">>, options=>#{'Uri-Path' => [<<"test">>]}, payload=> <<>>},
    Request2 = Request#{options:=#{'Uri-Path' => [<<"test">>], 
                                    'ETag' => [<<"ETag">>],
                                    'Content-Format' => <<"text/plain">>, 
                                    'Observe' => 12, 
                                    'Location-Path' => [<<"new_path">>]}},
    Payload = <<"Payload">>,
    Content = #coap_content{etag= <<"ETag">>, max_age=30, format= <<"text/plain">>, payload=Payload},
    [
        ?_assertEqual(Request#{code:={error, 'NotFound'}, options:=#{}}, 
            ecoap_utils:response({error, 'NotFound'}, Request)),
        ?_assertEqual(Request#{code:={ok, 'Content'}, options:=#{}, payload:=Payload}, 
            ecoap_utils:response({ok, 'Content'}, Payload, Request)),
        ?_assertEqual(Request#{code:={ok, 'Content'}, 
            options:=#{'ETag' => [<<"ETag">>], 'Max-Age' => 30, 'Content-Format' => <<"text/plain">>}, 
                payload:=Payload}, 
                    ecoap_utils:response({ok, 'Content'}, Content, Request)),
        ?_assertEqual(Content,
            ecoap_utils:get_content(ecoap_utils:response({ok, 'Content'}, Content, Request))),
        ?_assertEqual(#coap_content{etag= <<"ETag">>, format= <<"text/plain">>, options=#{'Location-Path' => [<<"new_path">>]}}, 
            ecoap_utils:get_content(Request2, extended)),
        ?_assertEqual(#{'Location-Path' => [<<"new_path">>]}, ecoap_utils:get_extra_options(Request2))
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
