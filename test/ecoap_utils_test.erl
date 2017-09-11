-module(ecoap_utils_test).
-include_lib("eunit/include/eunit.hrl").
-include_lib("ecoap_common/include/coap_def.hrl").
-include("ecoap.hrl").

utils_test_() ->
    OptionExample = #{'Size1' => 1024, 'Content-Format' => <<"text/plain">>},
    Msg1 = #coap_message{type='CON', id=123, code='GET', 
                    token= <<"Token">>, options=#{'Uri-Path' => [<<"test">>]}, payload= <<>>},
    Msg2 = #coap_message{
        options = #{'Uri-Path' => [<<"test">>], 
                    'ETag' => [<<"ETag">>],
                    'Content-Format' => <<"text/plain">>, 
                    'Observe' => 12, 
                    'Location-Path' => [<<"new_path">>]}},
    % Note the order of options will change
    [
        ?_assertEqual(OptionExample, ecoap_utils:add_options(OptionExample, #{})),
        ?_assertEqual(OptionExample, ecoap_utils:add_options(#{}, OptionExample)),
        ?_assertEqual(OptionExample#{'Size1' := 512}, ecoap_utils:add_option('Size1', 512, OptionExample)),

        % option in second map will supersed the same option in first map
        ?_assertEqual(OptionExample#{'ETag' => [<<"ETag">>], 'Size1' := 256}, 
            ecoap_utils:add_options(OptionExample, #{'ETag' => [<<"ETag">>], 'Size1' => 256})),
        ?_assertEqual(OptionExample#{'ETag' => [<<"ETag">>]}, 
            ecoap_utils:add_options(#{'Size1' => 256, 'ETag' => [<<"ETag">>]}, OptionExample)),

        ?_assertEqual(true, ecoap_utils:has_option('Size1', OptionExample)),
        ?_assertEqual(#{'Content-Format' => <<"text/plain">>},
            ecoap_utils:remove_option('Size1', OptionExample)),

        ?_assertEqual(Msg1#coap_message{options=#{'ETag' => [<<"ETag">>], 'Uri-Path' => [<<"test">>]}},
            ecoap_utils:set_option('ETag', [<<"ETag">>], Msg1)),
        ?_assertEqual(Msg1#coap_message{options=#{'Max-Age' => 5, 'ETag' => [<<"ETag">>], 'Uri-Path' => [<<"hello">>]}}, 
            ecoap_utils:set_options(#{'ETag' => [<<"ETag">>], 'Max-Age' => 5, 'Uri-Path' => [<<"hello">>]}, Msg1)),
        ?_assertEqual(#coap_content{etag= <<"ETag">>, format= <<"text/plain">>, options=#{'Location-Path' => [<<"new_path">>]}}, 
            ecoap_utils:get_content(Msg2, extended)),
        ?_assertEqual(#{'Location-Path' => [<<"new_path">>]}, ecoap_utils:get_extra_options(Msg2))
    ].

request_compose_test_() ->
    [
        ?_assertEqual(#coap_message{type='CON', code='GET'},
            ecoap_utils:request('CON', 'GET')),
        ?_assertEqual(#coap_message{type='CON', code='PUT', payload= <<"payload">>}, 
            ecoap_utils:request('CON', 'PUT', <<"payload">>)),
        ?_assertEqual(#coap_message{type='CON', code='PUT', options=#{'Uri-Path' => [<<"test">>]}, payload= <<"payload">>}, 
            ecoap_utils:request('CON', 'PUT', <<"payload">>, #{'Uri-Path' => [<<"test">>]}))
    ].

response_compose_test_() ->
    Request = #coap_message{type='CON', id=123, code='GET', 
                    token= <<"Token">>, options=#{'Uri-Path' => [<<"test">>]}, payload= <<>>},
    Payload = <<"Payload">>,
    Content = #coap_content{etag= <<"ETag">>, max_age=30, format= <<"text/plain">>, payload=Payload},
    [
        ?_assertEqual(Request#coap_message{code={error, 'NotFound'}, options=#{}}, 
            ecoap_utils:response({error, 'NotFound'}, Request)),
        ?_assertEqual(Request#coap_message{code={ok, 'Content'}, options=#{}, payload=Payload}, 
            ecoap_utils:response({ok, 'Content'}, Payload, Request)),
        ?_assertEqual(Request#coap_message{code={ok, 'Content'}, 
            options=#{'ETag' => [<<"ETag">>], 'Max-Age' => 30, 'Content-Format' => <<"text/plain">>}, 
                payload=Payload}, 
                    ecoap_utils:response({ok, 'Content'}, Content, Request)),
        ?_assertEqual(Content,
            ecoap_utils:get_content(ecoap_utils:response({ok, 'Content'}, Content, Request)))
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
