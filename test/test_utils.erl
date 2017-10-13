-module(test_utils).
-export([text_resource/1, text_resource/2, large_binary/2]).

-include("ecoap.hrl").

-record(coap_content, {
    etag = [] :: [binary()],
    max_age = ?DEFAULT_MAX_AGE :: non_neg_integer(),
    format = undefined :: undefined | binary() | non_neg_integer(),
    payload = <<>> :: binary()
}).

text_resource(Size) ->
    coap_content:new(large_binary(Size, <<"X">>), #{'Content-Format'=> <<"text/plain">>}).
text_resource(ETag, Size) ->
    coap_content:new(large_binary(Size, <<"X">>), #{'ETag'=>ETag, 'Content-Format'=> <<"text/plain">>}).

large_binary(Size, Acc) when Size > 2*byte_size(Acc) ->
    large_binary(Size, <<Acc/binary, Acc/binary>>);
large_binary(Size, Acc) ->
    Sup = binary:part(Acc, 0, Size-byte_size(Acc)),
    <<Acc/binary, Sup/binary>>.