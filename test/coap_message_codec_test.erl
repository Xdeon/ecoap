-module(coap_message_codec_test).
-include_lib("eunit/include/eunit.hrl").
-include_lib("ecoap/include/coap_def.hrl").

case1_test_() ->
    Raw = <<64,1,45,91,183,115,101,110,115,111,114,115,4,116,101,109,112,193,2>>, 
    Msg = #coap_message{type='CON', code='GET', id=11611, token= <<>>,
                options=#{'Block2'=>{0,false,64}, 'Uri-Path'=>[<<"sensors">>,<<"temp">>]}},
    test_codec(Raw, Msg).

case2_test_() ->
    Raw = <<1:2, 0:2, 0:4, 0:8, 0:16>>, 
    Msg = #coap_message{type='CON', code=undefined , id=0},
    test_codec(Raw, Msg).

case3_test_() ->
    Raw = <<1:2, 1:2, 2:4, 2:3, 1:5, 5:16, 555:16, 3:4, 13:4, 2:8, "www.example.com", 4:4, 2:4, 3456:16>>, 
    Msg = #coap_message{type='NON', code={ok,'Created'}, id=5, token= <<555:16>>, 
                options=#{'Uri-Port'=>3456, 'Uri-Host'=><<"www.example.com">>}},
    test_codec(Raw, Msg).

case4_test_() ->
    LongText = <<"abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz">>,
    Raw = <<1:2, 1:2, 2:4, 2:3, 1:5, 5:16, 555:16, 3:4, 14:4, 43:16, LongText/binary, 4:4, 2:4, 3456:16>>, 
    Msg = #coap_message{type='NON', code={ok,'Created'}, id=5, token= <<555:16>>, 
                options = #{'Uri-Port'=>3456, 'Uri-Host'=>LongText}},
    test_codec(Raw, Msg).

case5_test_() ->
    Raw = <<1:2, 1:2, 2:4, 2:3, 1:5, 5:16, 555:16, 3:4, 13:4, 2:8, "www.example.com", 4:4, 2:4, 3456:16, 255:8, "1234567">>,
    Msg = #coap_message{type='NON', code={ok,'Created'}, id=5, token= <<555:16>>, 
                options=#{'Uri-Port'=>3456, 'Uri-Host'=><<"www.example.com">>}, payload= <<"1234567">>},
    test_codec(Raw, Msg).

case6_test_() ->
    Raw = <<1:2, 1:2, 2:4, 2:3, 1:5, 5:16, 555:16, 3:4, 13:4, 2:8, "www.example.com", 4:4, 2:4, 3456:16, 14:4, 0:4, 1000:16, 255:8, "1234567">>,
    Msg = #coap_message{type='NON', code={ok,'Created'}, id=5, token= <<555:16>>, 
                options=#{1276=><<>>, 'Uri-Port'=>3456, 'Uri-Host'=><<"www.example.com">>}, payload= <<"1234567">>},
    test_codec(Raw, Msg).

case7_test_()-> 
    [
    test_codec(#coap_message{type='RST', id=0, options=#{}}),
    test_codec(#coap_message{type='CON', code='GET', id=100,
        options=#{'Block1'=>{0,true,128}, 'Observe'=>1}}),
    test_codec(#coap_message{type='NON', code='PUT', id=200, token= <<"token">>,
        options=#{'Uri-Path'=>[<<".well-known">>, <<"core">>]}}),
    test_codec(#coap_message{type='NON', code={ok, 'Content'}, id=300, token= <<"token">>,
        payload= <<"<url>">>, options=#{'Content-Format'=><<"application/link-format">>, 'Uri-Path'=>[<<".well-known">>, <<"core">>]}})
    ].

test_codec(Message) ->
    Message2 = coap_message:encode(Message),
    Message1 = coap_message:decode(Message2),
    ?_assertEqual(Message, Message1).

test_codec(Raw, Msg) ->
    Message = coap_message:decode(Raw),
    MsgBin = coap_message:encode(Message),
    [?_assertEqual(Msg, Message),
    ?_assertEqual(Raw, MsgBin)].
