-module(coap_iana).

-export([decode_type/1, encode_type/1, 
	decode_code/1, encode_code/1, 
	decode_content_format/1, encode_content_format/1 
	]).

-type coap_type_raw() :: 0..3.
-type coap_code_raw() :: {non_neg_integer(), non_neg_integer()}.
-type content_formats_code() :: non_neg_integer().

-spec decode_type(coap_type_raw()) -> coap_message:coap_type().
decode_type(0) -> 'CON';
decode_type(1) -> 'NON';
decode_type(2) -> 'ACK';
decode_type(3) -> 'RST'.

-spec encode_type(coap_message:coap_type()) -> coap_type_raw().
encode_type('CON') -> 0;
encode_type('NON') -> 1;
encode_type('ACK') -> 2;
encode_type('RST') -> 3.

% CoAP Request Codes:
%
% +------+--------+-----------+
% | Code | Name   | Reference |
% +------+--------+-----------+
% | 0.01 | GET    | [RFC7252] |
% | 0.02 | POST   | [RFC7252] |
% | 0.03 | PUT    | [RFC7252] |
% | 0.04 | DELETE | [RFC7252] |
% +------+--------+-----------+

% CoAP Response Codes:
%           
% +------+------------------------------+-----------+
% | Code | Description                  | Reference |
% +------+------------------------------+-----------+
% | 2.01 | Created                      | [RFC7252] |
% | 2.02 | Deleted                      | [RFC7252] |
% | 2.03 | Valid                        | [RFC7252] |
% | 2.04 | Changed                      | [RFC7252] |
% | 2.05 | Content                      | [RFC7252] |
% | 4.00 | Bad Request                  | [RFC7252] |
% | 4.01 | Unauthorized                 | [RFC7252] |
% | 4.02 | Bad Option                   | [RFC7252] |
% | 4.03 | Forbidden                    | [RFC7252] |
% | 4.04 | Not Found                    | [RFC7252] |
% | 4.05 | Method Not Allowed           | [RFC7252] |
% | 4.06 | Not Acceptable               | [RFC7252] |
% | 4.12 | Precondition Failed          | [RFC7252] |
% | 4.13 | Request Entity Too Large     | [RFC7252] |
% | 4.15 | Unsupported Content-Format   | [RFC7252] |
% | 5.00 | Internal Server Error        | [RFC7252] |
% | 5.01 | Not Implemented              | [RFC7252] |
% | 5.02 | Bad Gateway                  | [RFC7252] |
% | 5.03 | Service Unavailable          | [RFC7252] |
% | 5.04 | Gateway Timeout              | [RFC7252] |
% | 5.05 | Proxying Not Supported       | [RFC7252] |
% +------+------------------------------+-----------+

-spec decode_code(coap_code_raw()) -> coap_message:coap_code().
decode_code({0, 01}) -> 'GET';
decode_code({0, 02}) -> 'POST';
decode_code({0, 03}) -> 'PUT';
decode_code({0, 04}) -> 'DELETE';
decode_code({0, 05}) -> 'FETCH';
decode_code({0, 06}) -> 'PATCH';
decode_code({0, 07}) -> 'iPATCH';
% success is a tuple {ok, ...}
decode_code({2, 01}) -> {ok, 'Created'};
decode_code({2, 02}) -> {ok, 'Deleted'};
decode_code({2, 03}) -> {ok, 'Valid'};
decode_code({2, 04}) -> {ok, 'Changed'};
decode_code({2, 05}) -> {ok, 'Content'};
decode_code({2, 31}) -> {ok, 'Continue'}; % block
% error is a tuple {error, ...}
decode_code({4, 00}) -> {error, 'BadRequest'};
decode_code({4, 01}) -> {error, 'Unauthorized'};
decode_code({4, 02}) -> {error, 'BadOption'};
decode_code({4, 03}) -> {error, 'Forbidden'};
decode_code({4, 04}) -> {error, 'NotFound'};
decode_code({4, 05}) -> {error, 'MethodNotAllowed'};
decode_code({4, 06}) -> {error, 'NotAcceptable'};
decode_code({4, 08}) -> {error, 'RequestEntityIncomplete'}; % block
decode_code({4, 09}) -> {error, 'Conflict'};
decode_code({4, 12}) -> {error, 'PreconditionFailed'};
decode_code({4, 13}) -> {error, 'RequestEntityTooLarge'};
decode_code({4, 15}) -> {error, 'UnsupportedContentFormat'};
decode_code({4, 22}) -> {error, 'UnprocessableEntity'};
decode_code({5, 00}) -> {error, 'InternalServerError'};
decode_code({5, 01}) -> {error, 'NotImplemented'};
decode_code({5, 02}) -> {error, 'BadGateway'};
decode_code({5, 03}) -> {error, 'ServiceUnavailable'};
decode_code({5, 04}) -> {error, 'GatewayTimeout'};
decode_code({5, 05}) -> {error, 'ProxyingNotSupported'}.


-spec encode_code(coap_message:coap_code()) -> coap_code_raw().
encode_code('GET') -> {0, 01};
encode_code('POST') -> {0, 02};
encode_code('PUT') -> {0, 03};
encode_code('DELETE') -> {0, 04};
encode_code('FETCH') -> {0, 05};
encode_code('PATCH') -> {0, 06};
encode_code('iPATCH') -> {0, 07};
encode_code({ok, 'Created'}) -> {2, 01};
encode_code({ok, 'Deleted'}) -> {2, 02};
encode_code({ok, 'Valid'}) -> {2, 03};
encode_code({ok, 'Changed'}) -> {2, 04};
encode_code({ok, 'Content'}) -> {2, 05};
encode_code({ok, 'Continue'}) -> {2, 31};
encode_code({error, 'BadRequest'}) -> {4, 00};
encode_code({error, 'Unauthorized'}) -> {4, 01};
encode_code({error, 'BadOption'}) -> {4, 02};
encode_code({error, 'Forbidden'}) -> {4, 03};
encode_code({error, 'NotFound'}) -> {4, 04};
encode_code({error, 'MethodNotAllowed'}) -> {4, 05};
encode_code({error, 'NotAcceptable'}) -> {4, 06};
encode_code({error, 'RequestEntityIncomplete'}) -> {4, 08};
encode_code({error, 'Conflict'}) -> {4, 09};
encode_code({error, 'PreconditionFailed'}) -> {4, 12};
encode_code({error, 'RequestEntityTooLarge'}) -> {4, 13};
encode_code({error, 'UnsupportedContentFormat'}) -> {4, 15};
encode_code({error, 'UnprocessableEntity'}) -> {4, 22};
encode_code({error, 'InternalServerError'}) -> {5, 00};
encode_code({error, 'NotImplemented'}) -> {5, 01};
encode_code({error, 'BadGateway'}) -> {5, 02};
encode_code({error, 'ServiceUnavailable'}) -> {5, 03};
encode_code({error, 'GatewayTimeout'}) -> {5, 04};
encode_code({error, 'ProxyingNotSupported'}) -> {5, 05}.


%% CoAP Content-Formats Registry
%%
%% +--------------------------+----------+----+------------------------+
%% | Media type               | Encoding | ID | Reference              |
%% +--------------------------+----------+----+------------------------+
%% | text/plain;              | -        |  0 | [RFC2046] [RFC3676]    |
%% | charset=utf-8            |          |    | [RFC5147]              |
%% | application/link-format  | -        | 40 | [RFC6690]              |
%% | application/xml          | -        | 41 | [RFC3023]              |
%% | application/octet-stream | -        | 42 | [RFC2045] [RFC2046]    |
%% | application/exi          | -        | 47 | [REC-exi-20140211]     |
%% | application/json         | -        | 50 | [RFC7159]              |
%% +--------------------------+----------+----+------------------------+

-spec decode_content_format(content_formats_code()) -> binary() | content_formats_code().
decode_content_format(0) -> <<"text/plain">>;
decode_content_format(40) -> <<"application/link-format">>;
decode_content_format(41) -> <<"application/xml">>;
decode_content_format(42) -> <<"application/octet-stream">>;
decode_content_format(47) -> <<"application/exi">>;
decode_content_format(50) -> <<"application/json">>;
decode_content_format(60) -> <<"application/cbor">>;
decode_content_format(61) -> <<"application/cwt">>;
decode_content_format(11542) -> <<"application/vnd.oma.lwm2m+tlv">>;
% unknown content-format
decode_content_format(FormatCode) -> FormatCode.

-spec encode_content_format(binary() | content_formats_code()) -> content_formats_code().
encode_content_format(<<"text/plain">>) -> 0;
encode_content_format(<<"application/link-format">>) -> 40;
encode_content_format(<<"application/xml">>) -> 41;
encode_content_format(<<"application/octet-stream">>) -> 42;
encode_content_format(<<"application/exi">>) -> 47;
encode_content_format(<<"application/json">>) -> 50;
encode_content_format(<<"application/cbor">>) -> 60;
encode_content_format(<<"application/cwt">>) -> 61;
encode_content_format(<<"application/vnd.oma.lwm2m+tlv">>) -> 11542;
encode_content_format(Format) when is_integer(Format) -> Format.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

code() ->
	[
		{{0, 01}, 'GET'},
	    {{0, 02}, 'POST'},
	    {{0, 03}, 'PUT'},
	    {{0, 04}, 'DELETE'},
	    {{0, 05}, 'FETCH'},
	    {{0, 06}, 'PATCH'},
	    {{0, 07}, 'iPATCH'},
	    % success is a tuple {ok, ...}
	    {{2, 01}, {ok, 'Created'}},
	    {{2, 02}, {ok, 'Deleted'}},
	    {{2, 03}, {ok, 'Valid'}},
	    {{2, 04}, {ok, 'Changed'}},
	    {{2, 05}, {ok, 'Content'}},
	    {{2, 31}, {ok, 'Continue'}}, % block
	    % error is a tuple {error, ...}
	    {{4, 00}, {error, 'BadRequest'}},
	    {{4, 01}, {error, 'Unauthorized'}},
	    {{4, 02}, {error, 'BadOption'}},
	    {{4, 03}, {error, 'Forbidden'}},
	    {{4, 04}, {error, 'NotFound'}},
	    {{4, 05}, {error, 'MethodNotAllowed'}},
	    {{4, 06}, {error, 'NotAcceptable'}},
	    {{4, 08}, {error, 'RequestEntityIncomplete'}}, % block
	    {{4, 09}, {error, 'Conflict'}},
	    {{4, 12}, {error, 'PreconditionFailed'}},
	    {{4, 13}, {error, 'RequestEntityTooLarge'}},
	    {{4, 15}, {error, 'UnsupportedContentFormat'}},
	    {{4, 22}, {error, 'UnprocessableEntity'}},
	    {{5, 00}, {error, 'InternalServerError'}},
	    {{5, 01}, {error, 'NotImplemented'}},
	    {{5, 02}, {error, 'BadGateway'}},
	    {{5, 03}, {error, 'ServiceUnavailable'}},
	    {{5, 04}, {error, 'GatewayTimeout'}},
	    {{5, 05}, {error, 'ProxyingNotSupported'}}
	].

content_formats() ->
    [
	    {0, <<"text/plain">>},
	    {40, <<"application/link-format">>},
	    {41, <<"application/xml">>},
	    {42, <<"application/octet-stream">>},
	    {47, <<"application/exi">>},
	    {50, <<"application/json">>},
	    {60, <<"application/cbor">>},
	    {61, <<"application/cwt">>},
	    {11542, <<"application/vnd.oma.lwm2m+tlv">>}
    ].

decode_enum(TupleList, Key) ->
	decode_enum(TupleList, Key, undefined).

decode_enum(TupleList, Key, Default) ->
	case lists:keyfind(Key, 1, TupleList) of
		{_, Val} -> Val;
		false -> Default
	end.

encode_enum(TupleList, Key) ->
	encode_enum(TupleList, Key, undefined).

encode_enum(TupleList, Key, Default) ->
	case lists:keyfind(Key, 2, TupleList) of
		{Code, _} -> Code;
		false -> Default
	end.

enum_codec_test_() ->
	[
	[?_assertEqual(decode_enum(code(), Raw), decode_code(Raw)) || {Raw, _} <- code()],
	[?_assertEqual(encode_enum(code(), Code), encode_code(Code)) || {_, Code} <- code()],
	[?_assertEqual(decode_enum(content_formats(), Raw), decode_content_format(Raw)) || {Raw, _} <-content_formats()],
	[?_assertEqual(encode_enum(content_formats(), Code), encode_content_format(Code)) || {_, Code} <- content_formats()]
	].

-endif.