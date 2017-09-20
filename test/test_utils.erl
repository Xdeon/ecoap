-module(test_utils).
-export([text_resource/1, text_resource/2, large_binary/2, from_record/1, to_record/1]).

-include("ecoap.hrl").

-record(coap_content, {
    etag = [] :: [binary()],
    max_age = ?DEFAULT_MAX_AGE :: non_neg_integer(),
    format = undefined :: undefined | binary() | non_neg_integer(),
    payload = <<>> :: binary()
}).

text_resource(Size) ->
    coap_content:set_payload(large_binary(Size, <<"X">>), coap_content:options(#{'Content-Format'=> <<"text/plain">>}, coap_content:new())).
text_resource(ETag, Size) ->
    coap_content:set_payload(large_binary(Size, <<"X">>), coap_content:options(#{'ETag'=>ETag, 'Content-Format'=> <<"text/plain">>}, coap_content:new())).

large_binary(Size, Acc) when Size > 2*byte_size(Acc) ->
    large_binary(Size, <<Acc/binary, Acc/binary>>);
large_binary(Size, Acc) ->
    Sup = binary:part(Acc, 0, Size-byte_size(Acc)),
    <<Acc/binary, Sup/binary>>.

from_record(#coap_content{etag=ETag, max_age=MaxAge, format=Format, payload=Payload}) ->
    #{payload=>Payload, options=>#{'ETag' => ETag, 'Max-Age' => MaxAge, 'Content-Format' => Format}}.

to_record(#{payload:=Payload, options:=Options}) ->
    #coap_content{
        etag = coap_message:get_option('ETag', Options, []),
        max_age = coap_message:get_option('Max-Age', Options),
        format = coap_message:get_option('Content-Format', Options),
        payload = Payload
    }.