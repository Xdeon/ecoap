-module(coap_iana).

-export([decode_type/1, encode_type/1, 
	code/0, content_formats/0, 
	decode_enum/2, decode_enum/3, encode_enum/2, encode_enum/3]).

-type coap_code_raw() :: {non_neg_integer(), non_neg_integer()}.
-type content_formats_code() :: non_neg_integer().
-type coap_enum() :: [{coap_code_raw() | content_formats_code(), coap_code() | binary()}, ...].
-type enum_decode_key() :: coap_code_raw() | content_formats_code().
-type enum_encode_key() :: coap_code() | binary().
-type enum_default_val() :: integer() | undefined.

-include("coap_def.hrl").

-spec(decode_type(non_neg_integer()) -> coap_type()).
decode_type(0) -> 'CON';
decode_type(1) -> 'NON';
decode_type(2) -> 'ACK';
decode_type(3) -> 'RST'.

-spec(encode_type(coap_type()) -> non_neg_integer()).
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

-spec code() -> [{coap_code_raw(), coap_code()}, ...].
code() ->
	[
		{{0, 01}, 'GET'},
	    {{0, 02}, 'POST'},
	    {{0, 03}, 'PUT'},
	    {{0, 04}, 'DELETE'},
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
	    {{4, 12}, {error, 'PreconditionFailed'}},
	    {{4, 13}, {error, 'RequestEntityTooLarge'}},
	    {{4, 15}, {error, 'UnsupportedContentFormat'}},
	    {{5, 00}, {error, 'InternalServerError'}},
	    {{5, 01}, {error, 'NotImplemented'}},
	    {{5, 02}, {error, 'BadGateway'}},
	    {{5, 03}, {error, 'ServiceUnavailable'}},
	    {{5, 04}, {error, 'GatewayTimeout'}},
	    {{5, 05}, {error, 'ProxyingNotSupported'}}
	].

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

-spec content_formats() -> [{content_formats_code(), binary()}, ...].
content_formats() ->
    [
	    {0, <<"text/plain">>},
	    {40, <<"application/link-format">>},
	    {41, <<"application/xml">>},
	    {42, <<"application/octet-stream">>},
	    {47, <<"application/exi">>},
	    {50, <<"application/json">>},
	    {60, <<"application/cbor">>}
    ].

-spec decode_enum(coap_enum(), enum_decode_key()) -> enum_encode_key() | enum_default_val().
decode_enum(TupleList, Key) ->
	decode_enum(TupleList, Key, undefined).

-spec decode_enum(coap_enum(), enum_decode_key(), enum_default_val()) -> enum_encode_key() | enum_default_val().
decode_enum(TupleList, Key, Default) ->
	case lists:keyfind(Key, 1, TupleList) of
		{_, Val} -> Val;
		false -> Default
	end.

-spec encode_enum(coap_enum(), enum_encode_key()) -> enum_decode_key() | enum_default_val().
encode_enum(TupleList, Key) ->
	encode_enum(TupleList, Key, undefined).

-spec encode_enum(coap_enum(), enum_encode_key(), enum_default_val()) -> enum_decode_key() | enum_default_val().
encode_enum(TupleList, Key, Default) ->
	case lists:keyfind(Key, 2, TupleList) of
		{Code, _} -> Code;
		false -> Default
	end.
