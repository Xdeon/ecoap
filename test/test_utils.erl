-module(test_utils).
-export([text_resource/1, text_resource/2, large_binary/2]).

-include("ecoap.hrl").

text_resource(Size) ->
    text_resource(undefined, Size).
text_resource(ETag, Size) ->
	{large_binary(Size, <<"X">>), #{'ETag'=>ETag, 'Content-Format'=> <<"text/plain">>}}.

large_binary(Size, Acc) when Size > 2*byte_size(Acc) ->
    large_binary(Size, <<Acc/binary, Acc/binary>>);
large_binary(Size, Acc) ->
    Sup = binary:part(Acc, 0, Size-byte_size(Acc)),
    <<Acc/binary, Sup/binary>>.