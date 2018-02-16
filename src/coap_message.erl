%% Decoding/encoding based on emqttd_coap https://github.com/emqtt/emqttd_coap 
%% & gen_coap https://github.com/gotthardp/gen_coap
-module(coap_message).

-export([decode/1, encode/1]).
% getters of coap_message()
-export([get_type/1, get_code/1, get_id/1, get_token/1, get_options/1, get_payload/1]).
% setters of coap_message()
-export([set_type/2, set_code/2, set_id/2, set_token/2, set_options/2, set_payload/2]).
% utility functions for options
-export([get_option/2, get_option/3, set_option/3, merge_options/2]).
-export([add_option/3, add_options/2, has_option/2, remove_option/2, remove_options/2]).

-define(VERSION, 1).
-define(OPTION_IF_MATCH, 1).
-define(OPTION_URI_HOST, 3).
-define(OPTION_ETAG, 4).
-define(OPTION_IF_NONE_MATCH, 5).
-define(OPTION_OBSERVE, 6). % RFC 7641
-define(OPTION_URI_PORT, 7).
-define(OPTION_LOCATION_PATH, 8).
-define(OPTION_URI_PATH, 11).
-define(OPTION_CONTENT_FORMAT, 12).
-define(OPTION_MAX_AGE, 14).
-define(OPTION_URI_QUERY, 15).
-define(OPTION_ACCEPT, 17).
-define(OPTION_LOCATION_QUERY, 20).
-define(OPTION_BLOCK2, 23). % draft-ietf-core-block-17
-define(OPTION_BLOCK1, 27).
-define(OPTION_PROXY_URI, 35).
-define(OPTION_PROXY_SCHEME, 39).
-define(OPTION_SIZE1, 60).
-define(OPTION_SIZE2, 28).

-define(DEFAULT_COAP_PORT, 5683).
-define(DEFAULT_COAPS_PORT, 5684).
-define(DEFAULT_MAX_AGE, 60).

-include("coap_message.hrl").

-type coap_message() :: #coap_message{}.

-type msg_id() :: 0..65535.

-type coap_type() :: 'CON' | 'NON' | 'ACK' | 'RST' .

-type coap_method() :: 'GET' | 'POST' | 'PUT' | 'DELETE'.

-type success_code() :: 'Created' | 'Deleted' | 'Valid' | 'Changed' | 'Content' | 'Continue'.

-type error_code() :: 'BadRequest' 
                    | 'Unauthorized' 
                    | 'BadOption' 
                    | 'Forbidden' 
                    | 'NotFound' 
                    | 'MethodNotAllowed' 
                    | 'NotAcceptable' 
                    | 'RequestEntityIncomplete' 
                    | 'PreconditionFailed' 
                    | 'RequestEntityTooLarge' 
                    | 'UnsupportedContentFormat' 
                    | 'InternalServerError' 
                    | 'NotImplemented' 
                    | 'BadGateway' 
                    | 'ServiceUnavailable' 
                    | 'GatewayTimeout' 
                    | 'ProxyingNotSupported'.

-type coap_success() :: {ok, success_code()}. 

-type coap_error() :: {error, error_code()}.

-type coap_code() :: coap_method() | coap_success() | coap_error().

-type coap_option() :: 'If-Match'
                    | 'Uri-Host'
                    | 'ETag'
                    | 'If-None-Match'
                    | 'Uri-Port'
                    | 'Location-Path'
                    | 'Uri-Path'
                    | 'Content-Format'
                    | 'Max-Age'
                    | 'Uri-Query'
                    | 'Accept'
                    | 'Location-Query'
                    | 'Proxy-Uri'
                    | 'Proxy-Scheme'
                    | 'Size1'
                    | 'Observe'
                    | 'Block1'
                    | 'Block2'
                    | 'Size2'.

-type optionset() :: #{coap_option() | non_neg_integer() => term()}.

-export_type([coap_message/0, 
              msg_id/0, 
              coap_type/0, 
              coap_method/0, 
              success_code/0, 
              error_code/0, 
              coap_success/0, 
              coap_error/0, 
              coap_code/0, 
              coap_option/0, 
              optionset/0]).

% utility functions
-spec get_type(coap_message()) -> coap_type().
get_type(#coap_message{type=Type}) -> Type.

-spec set_type(coap_type(), coap_message()) -> coap_message().
set_type(Type, Msg) -> Msg#coap_message{type=Type}.

-spec get_code(coap_message()) -> undefined | coap_code().
get_code(#coap_message{code=Code}) -> Code.

-spec set_code(coap_code(), coap_message()) -> coap_message().
set_code(Code, Msg) -> Msg#coap_message{code=Code}.

% shortcut function for reset generation
-spec get_id(binary() | coap_message()) -> msg_id().
get_id(<<_:16, MsgId:16, _Tail/bytes>>) -> MsgId;
get_id(#coap_message{id=MsgId}) -> MsgId.

-spec set_id(msg_id(), coap_message()) -> coap_message().
set_id(MsgId, Msg) -> Msg#coap_message{id=MsgId}.

-spec get_token(coap_message()) -> binary().
get_token(#coap_message{token=Token}) -> Token.

-spec set_token(binary(), coap_message()) -> coap_message().
set_token(Token, Msg) -> Msg#coap_message{token=Token}.

-spec get_options(coap_message()) -> optionset().
get_options(#coap_message{options=Options}) -> Options.

-spec set_options(optionset(), coap_message()) -> coap_message().
set_options(Options, Msg) -> Msg#coap_message{options=Options}.

-spec get_payload(coap_message()) -> binary().
get_payload(#coap_message{payload=Payload}) -> Payload.

-spec set_payload(binary(), coap_message()) -> coap_message().
set_payload(Payload, Msg) -> Msg#coap_message{payload=Payload}.

-spec get_option(coap_option(), coap_message() | optionset()) -> term().
get_option(Option, Source) ->
    get_option(Option, Source, undefined).

-spec get_option(coap_option(), coap_message() | optionset(), term()) -> term().
get_option(Option, #coap_message{options=Options}, Default) ->
    get_option_helper(Option, Options, Default);
get_option(Option, Options, Default) ->
    get_option_helper(Option, Options, Default).

get_option_helper(Option, Options, Default) ->
    maps:get(Option, Options, Default).

-spec set_option(coap_option(), term(), coap_message()) -> coap_message().
set_option(Option, Value, Msg=#coap_message{options=Options}) ->
    Msg#coap_message{options=add_option(Option, Value, Options)}.

-spec merge_options(optionset(), coap_message()) -> coap_message().
merge_options(Options, Msg) when map_size(Options) =:= 0 -> 
    Msg;
merge_options(Options2, Msg=#coap_message{options=Options1}) ->
   Msg#coap_message{options=add_options(Options1, Options2)}.

-spec add_option(coap_option(), term(), optionset()) -> optionset().
% omit option for its default value
add_option(_, [], Options) -> Options;
add_option(_, undefined, Options) -> Options;
add_option('Max-Age', ?DEFAULT_MAX_AGE, Options) -> Options;
add_option('Uri-Port', ?DEFAULT_COAP_PORT, Options) -> Options;
add_option('Uri-Port', ?DEFAULT_COAPS_PORT, Options) -> Options;
add_option(Option, Value, Options) -> Options#{Option => Value}.

-spec add_options(optionset(), optionset()) -> optionset().
add_options(Options1, Options2) ->
    maps:merge(Options1, Options2).

-spec has_option(coap_option(), coap_message() | optionset()) -> boolean().
has_option(Option, #coap_message{options=Options}) ->
    has_option_helper(Option, Options);
has_option(Option, Options) ->
    has_option_helper(Option, Options).

has_option_helper(Option, Options) ->
    maps:is_key(Option, Options).

-spec remove_option(coap_option(), Source) -> Source when Source :: coap_message() | optionset().
remove_option(Option, Msg=#coap_message{options=Options}) ->
    Msg#coap_message{options=remove_option_helper(Option, Options)};
remove_option(Option, Options) ->
    remove_option_helper(Option, Options).

remove_option_helper(Option, Options) ->
    maps:remove(Option, Options).

-spec remove_options([coap_option()], Source) -> Source when Source :: coap_message() | optionset().
remove_options(OptionList, Msg=#coap_message{options=Options}) ->
    Msg#coap_message{options=remove_options_helper(OptionList, Options)};
remove_options(OptionList, Options) ->
    remove_options_helper(OptionList, Options).

remove_options_helper(OptionList, Options) ->
    maps:without(OptionList, Options).

% CoAP Message Format
%
%  0                   1                   2                   3
%  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
% +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
% |Ver| T |  TKL  |      Code     |          Message ID           |
% +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
% |   Token (if any, TKL bytes) ...                               |
% +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
% |   Options (if any) ...                                        |
% +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
% |1 1 1 1 1 1 1 1|    Payload (if any) ...                       |
% +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

% CoAP Option Value
%
% +--------+------------------+-----------+
% | Number | Name             | Reference |
% +--------+------------------+-----------+
% |      0 | (Reserved)       | [RFC7252] |
% |      1 | If-Match         | [RFC7252] |
% |      3 | Uri-Host         | [RFC7252] |
% |      4 | ETag             | [RFC7252] |
% |      5 | If-None-Match    | [RFC7252] |
% |      7 | Uri-Port         | [RFC7252] |
% |      8 | Location-Path    | [RFC7252] |
% |     11 | Uri-Path         | [RFC7252] |
% |     12 | Content-Format   | [RFC7252] |
% |     14 | Max-Age          | [RFC7252] |
% |     15 | Uri-Query        | [RFC7252] |
% |     17 | Accept           | [RFC7252] |
% |     20 | Location-Query   | [RFC7252] |
% |     35 | Proxy-Uri        | [RFC7252] |
% |     39 | Proxy-Scheme     | [RFC7252] |
% |     60 | Size1            | [RFC7252] |
% |    128 | (Reserved)       | [RFC7252] |
% |    132 | (Reserved)       | [RFC7252] |
% |    136 | (Reserved)       | [RFC7252] |
% |    140 | (Reserved)       | [RFC7252] |
% +--------+------------------+-----------+

% +-----+---+---+---+---+----------------+--------+--------+----------+
% | No. | C | U | N | R | Name           | Format | Length | Default  |
% +-----+---+---+---+---+----------------+--------+--------+----------+
% |   1 | x |   |   | x | If-Match       | opaque | 0-8    | (none)   |
% |   3 | x | x | - |   | Uri-Host       | string | 1-255  | (see     |
% |     |   |   |   |   |                |        |        | below)   |
% |   4 |   |   |   | x | ETag           | opaque | 1-8    | (none)   |
% |   5 | x |   |   |   | If-None-Match  | empty  | 0      | (none)   |
% |   7 | x | x | - |   | Uri-Port       | uint   | 0-2    | (see     |
% |     |   |   |   |   |                |        |        | below)   |
% |   8 |   |   |   | x | Location-Path  | string | 0-255  | (none)   |
% |  11 | x | x | - | x | Uri-Path       | string | 0-255  | (none)   |
% |  12 |   |   |   |   | Content-Format | uint   | 0-2    | (none)   |
% |  14 |   | x | - |   | Max-Age        | uint   | 0-4    | 60       |
% |  15 | x | x | - | x | Uri-Query      | string | 0-255  | (none)   |
% |  17 | x |   |   |   | Accept         | uint   | 0-2    | (none)   |
% |  20 |   |   |   | x | Location-Query | string | 0-255  | (none)   |
% |  35 | x | x | - |   | Proxy-Uri      | string | 1-1034 | (none)   |
% |  39 | x | x | - |   | Proxy-Scheme   | string | 1-255  | (none)   |
% |  60 |   |   | x |   | Size1          | uint   | 0-4    | (none)   |
% +-----+---+---+---+---+----------------+--------+--------+----------+
%          C=Critical, U=Unsafe, N=NoCacheKey, R=Repeatable

%%--------------------------------------------------------------------
%% Decode CoAP Message
%%--------------------------------------------------------------------

% empty message only contains the 4-byte header
-spec decode(binary()) -> coap_message() | no_return().
decode(<<?VERSION:2, Type:2, 0:4, 0:3, 0:5, MsgId:16>>) ->
    #coap_message{type=coap_iana:decode_type(Type), id=MsgId};

decode(<<?VERSION:2, Type:2, TKL:4, Class:3, DetailedCode:5, MsgId:16, Token:TKL/bytes, Tail/bytes>>) ->
    {Options, Payload} = decode_option_list(Tail),
    #coap_message{
        type=coap_iana:decode_type(Type),
        code=coap_iana:decode_code({Class, DetailedCode}),
        id=MsgId,
        token=Token,
        options=maps:from_list(Options),
        payload=Payload}.

decode_option_list(Tail) ->
    decode_option_list(Tail, 0, []).

% option parsing is based on Patrick's CoAP Message Parsing in Erlang
% https://gist.github.com/azdle/b2d477ff183b8bbb0aa0

decode_option_list(<<>>, _LastNum, OptionList) ->
    {OptionList, <<>>};
% RFC7252: The presence of a marker followed by a zero-length payload MUST be processed as a message format error.
decode_option_list(<<16#FF, Payload/bytes>>, _LastNum, OptionList) when Payload /= <<>> ->
    {OptionList, Payload};
decode_option_list(<<Delta:4, Len:4, Tail/bytes>>, LastNum, OptionList) ->
    {Tail1, OptNum} = if
        Delta =< 12 ->
            {Tail, LastNum + Delta};
        Delta == 13 ->
            <<ExtOptNum, NewTail1/bytes>> = Tail,
            {NewTail1, LastNum + ExtOptNum + 13};
        Delta == 14 ->
            <<ExtOptNum:16, NewTail1/bytes>> = Tail,
            {NewTail1, LastNum + ExtOptNum + 269}
    end,
    {Tail2, OptLen} = if
        Len < 13 ->
            {Tail1, Len};
        Len == 13 ->
            <<ExtOptLen, NewTail2/bytes>> = Tail1,
            {NewTail2, ExtOptLen + 13};
        Len == 14 ->
            <<ExtOptLen:16, NewTail2/bytes>> = Tail1,
            {NewTail2, ExtOptLen + 269}
    end,
    case Tail2 of
        <<OptVal:OptLen/bytes, NextOpt/bytes>> ->
            decode_option_list(NextOpt, OptNum, append_option(decode_option({OptNum, OptVal}), OptionList));
        <<>> ->
            decode_option_list(<<>>, OptNum, append_option(decode_option({OptNum, <<>>}), OptionList))
    end.

% decode_option_list(<<>>, _, Options) ->
%     {Options, <<>>};
% decode_option_list(<<16#FF, Payload/binary>>, _, Options) ->
%     {Options, Payload};
% decode_option_list(<<Delta:4, OptLen:4, Bin/binary>>, OptNum, Options) when Delta =< 12 ->
%     parse_option({OptLen, Bin}, OptNum + Delta, Options);
% decode_option_list(<<13:4, OptLen:4, Delta:8, Bin/binary>>, OptNum, Options) ->
%     parse_option({OptLen, Bin}, OptNum + Delta + 13, Options);
% decode_option_list(<<14:4, OptLen:4, Delta:16/big-integer, Bin/binary>>, OptNum, Options) ->
%     parse_option({OptLen, Bin}, OptNum + Delta + 269, Options).

% parse_option({OptLen, Bin}, OptNum, Options) when OptLen =< 12 ->
%     parse_next({OptLen, Bin}, OptNum, Options);
% parse_option({13, <<Len:8, Bin/binary>>}, OptNum, Options) ->
%     OptLen = Len + 13,
%     parse_next({OptLen, Bin}, OptNum, Options);
% parse_option({14, <<Len:16/big-integer, Bin/binary>>}, OptNum, Options) ->
%     OptLen = Len + 269,
%     parse_next({OptLen, Bin}, OptNum, Options).

% parse_next({_OptLen, <<>>}, OptNum, Options) ->
%     decode_option_list(<<>>, OptNum, append_option(decode_option({OptNum, <<>>}), Options));
% parse_next({OptLen, Bin}, OptNum, Options) ->
%     <<OptVal:OptLen/binary, Left/binary>> = Bin,
%     decode_option_list(Left, OptNum, append_option(decode_option({OptNum, OptVal}), Options)).

% put options of the same id into one list
% append_option({SameOptId, OptVal2}, OptionList0=[{SameOptId, OptVal1} | OptionList]) ->
%     case is_repeatable_option(SameOptId) of
%         true ->
%             % we must keep the order
%             [{SameOptId, lists:append(OptVal1, [OptVal2])} | OptionList];
%         false ->
%             case is_critical_option(SameOptId) of
%                 true -> throw({error, atom_to_list(SameOptId)++" is not repeatable"});
%                 false -> OptionList0
%             end
%     end;
% append_option({OptId2, OptVal2}, OptionList) ->
%     case is_repeatable_option(OptId2) of
%         true -> [{OptId2, [OptVal2]} | OptionList];
%         false -> [{OptId2, OptVal2} | OptionList]
%     end.

% put options of the same id into one list
append_option({SameOptId, OptVal2}, [{SameOptId, OptVal1} | OptionList]) ->
    case is_repeatable_option(SameOptId) of
        % each supernumerary option occurrence that appears subsequently in the message will replace existing one
        % we must keep the order
        true -> [{SameOptId, lists:append(OptVal1, [OptVal2])} | OptionList];
        false -> [{SameOptId, OptVal2} | OptionList]
    end;
append_option({OptId2, OptVal2}, OptionList) ->
    case is_repeatable_option(OptId2) of
        true -> [{OptId2, [OptVal2]} | OptionList];
        false -> [{OptId2, OptVal2} | OptionList]
    end.

% TODO: Shall we follow the specification strictly and react to unrecognized options (including repeated non-repeatable ones)?

% RFC 7252
-spec decode_option({non_neg_integer(), _}) -> {coap_option()|non_neg_integer(), _}.
decode_option({?OPTION_IF_MATCH, OptVal}) -> {'If-Match', OptVal};
decode_option({?OPTION_URI_HOST, OptVal}) -> {'Uri-Host', OptVal};
decode_option({?OPTION_ETAG, OptVal}) -> {'ETag', OptVal};
decode_option({?OPTION_IF_NONE_MATCH, <<>>}) -> {'If-None-Match', true};
decode_option({?OPTION_URI_PORT, OptVal}) -> {'Uri-Port', binary:decode_unsigned(OptVal)};
decode_option({?OPTION_LOCATION_PATH, OptVal}) -> {'Location-Path', OptVal};
decode_option({?OPTION_URI_PATH, OptVal}) -> {'Uri-Path', OptVal};
decode_option({?OPTION_CONTENT_FORMAT, OptVal}) ->
    Num = binary:decode_unsigned(OptVal),
    {'Content-Format', coap_iana:decode_content_format(Num)};
decode_option({?OPTION_MAX_AGE, OptVal}) -> {'Max-Age', binary:decode_unsigned(OptVal)};
decode_option({?OPTION_URI_QUERY, OptVal}) -> {'Uri-Query', OptVal};
decode_option({?OPTION_ACCEPT, OptVal}) -> 
    Num = binary:decode_unsigned(OptVal),
    {'Accept', coap_iana:decode_content_format(Num)};
    % {'Accept', binary:decode_unsigned(OptVal)};
decode_option({?OPTION_LOCATION_QUERY, OptVal}) -> {'Location-Query', OptVal};
decode_option({?OPTION_PROXY_URI, OptVal}) -> {'Proxy-Uri', OptVal};
decode_option({?OPTION_PROXY_SCHEME, OptVal}) -> {'Proxy-Scheme', OptVal};
decode_option({?OPTION_SIZE1, OptVal}) -> {'Size1', binary:decode_unsigned(OptVal)};
% RFC 7641
decode_option({?OPTION_OBSERVE, OptVal}) -> {'Observe', binary:decode_unsigned(OptVal)};
% RFC 7959
decode_option({?OPTION_BLOCK2, OptVal}) -> {'Block2', decode_block(OptVal)};
decode_option({?OPTION_BLOCK1, OptVal}) -> {'Block1', decode_block(OptVal)};
decode_option({?OPTION_SIZE2, OptVal}) -> {'Size2', binary:decode_unsigned(OptVal)};
% unknown option
decode_option({OptNum, OptVal}) -> {OptNum, OptVal}.

decode_block(<<>>) -> decode_block1(0, 0, 0);
decode_block(<<Num:4, M:1, SizEx:3>>) -> decode_block1(Num, M, SizEx);
decode_block(<<Num:12, M:1, SizEx:3>>) -> decode_block1(Num, M, SizEx);
decode_block(<<Num:20, M:1, SizEx:3>>) -> decode_block1(Num, M, SizEx).

decode_block1(Num, M, SizEx) ->
    {Num, if M == 0 -> false; true -> true end, 2 bsl (SizEx+3)}. % same as 2**(SizEx+4)

%%--------------------------------------------------------------------
%% Serialize CoAP Message
%%--------------------------------------------------------------------

% empty message
-spec encode(coap_message()) -> binary().
encode(#coap_message{type=Type, code=undefined, id=MsgId}) ->
    <<?VERSION:2, (coap_iana:encode_type(Type)):2, 0:4, 0:3, 0:5, MsgId:16>>;
encode(#coap_message{type=Type, code=Code, id=MsgId, token=Token, options=Options, payload=Payload}) ->
    TKL = byte_size(Token),
    {Class, DetailedCode} = coap_iana:encode_code(Code),
    Tail = encode_option_list(maps:to_list(Options), Payload),
    <<?VERSION:2, (coap_iana:encode_type(Type)):2, TKL:4, Class:3, DetailedCode:5, MsgId:16, Token:TKL/bytes, Tail/bytes>>.

encode_option_list(Options, <<>>) ->
    encode_option_list1(Options);
encode_option_list(Options, Payload) ->
    <<(encode_option_list1(Options))/bytes, 16#FF, Payload/bytes>>.

encode_option_list1(Options) ->
    Options1 = encode_options(Options, []),
    % sort before encoding so we can calculate the deltas
    % the sort is stable; it maintains relative order of values with equal keys
    encode_option_list(lists:keysort(1, Options1), 0, <<>>).

encode_options([{_OptId, undefined} | OptionList], Acc) ->
    encode_options(OptionList, Acc);
encode_options([{OptId, OptVal} | OptionList], Acc) ->
    case is_repeatable_option(OptId) of
        true ->
            encode_options(OptionList, split_and_encode_option({OptId, OptVal}, Acc));
        false ->
            encode_options(OptionList, [encode_option({OptId, OptVal}) | Acc])
    end;
encode_options([], Acc) ->
    Acc.

split_and_encode_option({OptId, [undefined | OptVals]}, Acc) ->
    split_and_encode_option({OptId, OptVals}, Acc);
split_and_encode_option({OptId, [OptVal1 | OptVals]}, Acc) ->
    % we must keep the order
    [encode_option({OptId, OptVal1}) | split_and_encode_option({OptId, OptVals}, Acc)];
split_and_encode_option({_OptId, []}, Acc) ->
    Acc.

encode_option_list([{OptNum, OptVal} | OptionList], LastNum, Acc) ->
    {Delta, ExtNum} = if
        OptNum - LastNum >= 269 ->
            {14, <<(OptNum - LastNum - 269):16>>};
        OptNum - LastNum >= 13 ->
            {13, <<(OptNum - LastNum - 13)>>};
        true ->
            {OptNum - LastNum, <<>>}
    end,
    {Len, ExtLen} = if
        byte_size(OptVal) >= 269 ->
            {14, <<(byte_size(OptVal) - 269):16>>};
        byte_size(OptVal) >= 13 ->
            {13, <<(byte_size(OptVal) - 13)>>};
        true ->
            {byte_size(OptVal), <<>>}
    end,
    Acc2 = <<Acc/bytes, Delta:4, Len:4, ExtNum/bytes, ExtLen/bytes, OptVal/bytes>>,
    encode_option_list(OptionList, OptNum, Acc2);

encode_option_list([], _LastNum, Acc) ->
    Acc.

% RFC 7252
-spec encode_option({coap_option()|non_neg_integer(), _}) -> {non_neg_integer(), _}.
encode_option({'If-Match', OptVal}) -> {?OPTION_IF_MATCH, OptVal};
encode_option({'Uri-Host', OptVal}) -> {?OPTION_URI_HOST, OptVal};
encode_option({'ETag', OptVal}) -> {?OPTION_ETAG, OptVal};
encode_option({'If-None-Match', true}) -> {?OPTION_IF_NONE_MATCH, <<>>};
encode_option({'Uri-Port', OptVal}) -> {?OPTION_URI_PORT, binary:encode_unsigned(OptVal)};
encode_option({'Location-Path', OptVal}) -> {?OPTION_LOCATION_PATH, OptVal};
encode_option({'Uri-Path', OptVal}) -> {?OPTION_URI_PATH, OptVal};
encode_option({'Content-Format', OptVal}) when is_integer(OptVal) ->
    {?OPTION_CONTENT_FORMAT, binary:encode_unsigned(OptVal)};
encode_option({'Content-Format', OptVal}) ->
    Num = coap_iana:encode_content_format(OptVal),
    {?OPTION_CONTENT_FORMAT, binary:encode_unsigned(Num)};
encode_option({'Max-Age', OptVal}) -> {?OPTION_MAX_AGE, binary:encode_unsigned(OptVal)};
encode_option({'Uri-Query', OptVal}) -> {?OPTION_URI_QUERY, OptVal};
encode_option({'Accept', OptVal}) when is_integer(OptVal) -> 
    {?OPTION_ACCEPT, binary:encode_unsigned(OptVal)};
encode_option({'Accept', OptVal}) -> 
    Num = coap_iana:encode_content_format(OptVal),
    {?OPTION_ACCEPT, binary:encode_unsigned(Num)};
encode_option({'Location-Query', OptVal}) -> {?OPTION_LOCATION_QUERY, OptVal};
encode_option({'Proxy-Uri', OptVal}) -> {?OPTION_PROXY_URI, OptVal};
encode_option({'Proxy-Scheme', OptVal}) -> {?OPTION_PROXY_SCHEME, OptVal};
encode_option({'Size1', OptVal}) -> {?OPTION_SIZE1, binary:encode_unsigned(OptVal)};
% RFC 7641
encode_option({'Observe', OptVal}) -> {?OPTION_OBSERVE, binary:encode_unsigned(OptVal)};
% RFC 7959
encode_option({'Block2', OptVal}) -> {?OPTION_BLOCK2, encode_block(OptVal)};
encode_option({'Block1', OptVal}) -> {?OPTION_BLOCK1, encode_block(OptVal)};
encode_option({'Size2', OptVal}) -> {?OPTION_SIZE2, binary:encode_unsigned(OptVal)};
% unknown option
encode_option({OptNum, OptVal}) when is_integer(OptNum) ->
    {OptNum, OptVal}.

encode_block({Num, More, Size}) ->
    encode_block1(Num, if More -> 1; true -> 0 end, trunc(math:log2(Size))-4).

encode_block1(0, 0, 0) -> <<>>;
encode_block1(Num, M, SizEx) when Num < 16 ->
    <<Num:4, M:1, SizEx:3>>;
encode_block1(Num, M, SizEx) when Num < 4096 ->
    <<Num:12, M:1, SizEx:3>>;
encode_block1(Num, M, SizEx) ->
    <<Num:20, M:1, SizEx:3>>.

is_repeatable_option('If-Match') -> true;
is_repeatable_option('ETag') -> true;
is_repeatable_option('Location-Path') -> true;
is_repeatable_option('Uri-Path') -> true;
is_repeatable_option('Uri-Query') -> true;
is_repeatable_option('Location-Query') -> true;
is_repeatable_option(_Else) -> false.

% is_critical_option('If-Match') -> true;
% is_critical_option('Uri-Host') -> true;
% is_critical_option('If-None-Match') -> true;
% is_critical_option('Uri-Port') -> true;
% is_critical_option('Uri-Path') -> true;
% is_critical_option('Uri-Query') -> true;
% is_critical_option('Accept') -> true;
% is_critical_option('Proxy-Uri') -> true;
% is_critical_option('Proxy-Scheme') -> true;
% is_critical_option(OptNum) when is_integer(OptNum) -> 
%     case OptNum band 1 of
%         1 -> true;
%         0 -> false
%     end;
% is_critical_option(_Else) -> false.

% option_encode_unsigned({Opt, undefined}) -> [];
% option_encode_unsigned({Opt, Num}) -> {Opt, binary:encode_unsigned(Num)}.

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

api_test_() ->
    OptionExample = #{'Size1' => 1024, 'Content-Format' => <<"text/plain">>, 'Uri-Path' => [<<"test">>], 'Block2' => {1, true, 64}},
    [
        ?_assertEqual(OptionExample, coap_message:add_options(OptionExample, #{})),
        ?_assertEqual(OptionExample, coap_message:add_options(#{}, OptionExample)),
        ?_assertEqual(OptionExample#{'Size1' := 512}, coap_message:add_option('Size1', 512, OptionExample)),

        % option in second map will supersed the same option in first map
        ?_assertEqual(OptionExample#{'ETag' => [<<"ETag">>], 'Size1' := 256}, 
            coap_message:add_options(OptionExample, #{'ETag' => [<<"ETag">>], 'Size1' => 256})),
        ?_assertEqual(OptionExample#{'ETag' => [<<"ETag">>]}, 
            coap_message:add_options(#{'Size1' => 256, 'ETag' => [<<"ETag">>]}, OptionExample)),

        ?_assertEqual(true, coap_message:has_option('Size1', OptionExample)),

        ?_assertEqual(#{'Content-Format' => <<"text/plain">>, 'Uri-Path' => [<<"test">>], 'Block2' => {1, true, 64}},
            coap_message:remove_option('Size1', OptionExample)),
        ?_assertEqual(#{'Size1' => 1024, 'Content-Format' => <<"text/plain">>},
            coap_message:remove_options(['Uri-Path', 'Block2'], OptionExample))
    ].

case1_test_() ->
    Raw = <<64,1,45,91,183,115,101,110,115,111,114,115,4,116,101,109,112,193,2>>, 
    Msg = #coap_message{type='CON', code='GET', id=11611, options=#{'Block2' => {0,false,64}, 'Uri-Path' => [<<"sensors">>,<<"temp">>]}},
    test_codec(Raw, Msg).

case2_test_() ->
    Raw = <<1:2, 0:2, 0:4, 0:8, 0:16>>, 
    Msg = #coap_message{type='CON', id=0},
    test_codec(Raw, Msg).

case3_test_() ->
    Raw = <<1:2, 1:2, 2:4, 2:3, 1:5, 5:16, 555:16, 3:4, 13:4, 2:8, "www.example.com", 4:4, 2:4, 3456:16>>, 
    Msg = #coap_message{type='NON', code={ok, 'Created'}, id=5, token= <<555:16>>, options=#{'Uri-Port' => 3456, 'Uri-Host' => <<"www.example.com">>}},
    test_codec(Raw, Msg).

case4_test_() ->
    LongText = <<"abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz">>,
    Raw = <<1:2, 1:2, 2:4, 2:3, 1:5, 5:16, 555:16, 3:4, 14:4, 43:16, LongText/binary, 4:4, 2:4, 3456:16>>, 
    Msg = #coap_message{type='NON', code={ok, 'Created'}, id=5, token= <<555:16>>, options=#{'Uri-Port' => 3456, 'Uri-Host' => LongText}},
    test_codec(Raw, Msg).

case5_test_() ->
    Raw = <<1:2, 1:2, 2:4, 2:3, 1:5, 5:16, 555:16, 3:4, 13:4, 2:8, "www.example.com", 4:4, 2:4, 3456:16, 255:8, "1234567">>,
    Msg = #coap_message{type='NON', code={ok, 'Created'}, id=5, token= <<555:16>>, options=#{'Uri-Port' => 3456, 'Uri-Host' => <<"www.example.com">>}, payload= <<"1234567">>},
    test_codec(Raw, Msg).

case6_test_() ->
    Raw = <<1:2, 1:2, 2:4, 2:3, 1:5, 5:16, 555:16, 3:4, 13:4, 2:8, "www.example.com", 4:4, 2:4, 3456:16, 14:4, 0:4, 1000:16, 255:8, "1234567">>,
    Msg = #coap_message{type='NON', code={ok, 'Created'}, id=5, token= <<555:16>>, options=#{1276 => <<>>, 'Uri-Port' => 3456, 'Uri-Host' => <<"www.example.com">>}, payload= <<"1234567">>},
    test_codec(Raw, Msg).

case7_test_()-> 
    [
    test_codec(#coap_message{type='RST', id=0}),
    test_codec(#coap_message{type='CON', code='GET', id=100, options=#{'Block1' => {0,true,128}, 'Observe' => 1}}),
    test_codec(#coap_message{type='NON', code='PUT', id=200, token= <<"token">>, options=#{'Uri-Path' => [<<".well-known">>, <<"core">>]}}),
    test_codec(#coap_message{type='NON', code={ok, 'Content'}, id=300, token= <<"token">>, 
        options=#{'Content-Format' => <<"application/link-format">>, 'Uri-Path' => [<<".well-known">>, <<"core">>]}, payload= <<"<url>">>})
    ].

case8_test_() ->
    Raw = <<1:2, 0:2, 2:4, 0:8, 5:16, 333:16, 3:4, 15:4, "www.example.com">>,
    ?_assertMatch({'EXIT', _}, catch coap_message:decode(Raw)).

case9_test_() ->
    Raw = <<1:2, 0:2, 2:4, 0:8, 5:16, 333:16, 3:4, 13:4, 15:8, "www.example.com">>,
    ?_assertMatch({'EXIT', _}, catch coap_message:decode(Raw)).

test_codec(Message) ->
    Message2 = coap_message:encode(Message),
    Message1 = coap_message:decode(Message2),
    ?_assertEqual(Message, Message1).

test_codec(Raw, Msg) ->
    Message = coap_message:decode(Raw),
    MsgBin = coap_message:encode(Message),
    [
        ?_assertEqual(Msg, Message),
        ?_assertEqual(Raw, MsgBin)
    ].

-endif.