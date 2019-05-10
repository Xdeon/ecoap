-module(test_utils).
-export([text_resource/1, text_resource/2]).

text_resource(Size) ->
    coap_content:new(binary:copy(<<"X">>, Size), #{'Content-Format'=> <<"text/plain">>}).

text_resource(ETag, Size) ->
    coap_content:new(binary:copy(<<"X">>, Size), #{'ETag'=>ETag, 'Content-Format'=> <<"text/plain">>}).