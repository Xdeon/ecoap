-module(test_utils).
-export([text_resource/1, text_resource/2, large_binary/2]).

-include_lib("ecoap_common/include/coap_def.hrl").

text_resource(Size) ->
    text_resource(undefined, Size).
text_resource(ETag, Size) ->
    #coap_content{etag=ETag, format= <<"text/plain">>, payload=large_binary(Size, <<"X">>)}.

large_binary(Size, Acc) when Size > 2*byte_size(Acc) ->
    large_binary(Size, <<Acc/binary, Acc/binary>>);
large_binary(Size, Acc) ->
    Sup = binary:part(Acc, 0, Size-byte_size(Acc)),
    <<Acc/binary, Sup/binary>>.