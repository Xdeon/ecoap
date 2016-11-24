%% Decoding/encoding based on emqttd_coap https://github.com/emqtt/emqttd_coap 
%% & gen_coap https://github.com/gotthardp/gen_coap
-module(coap_message).

-export([decode/1, encode/1]).

-import(coap_iana, [content_formats/0, code/0]).
-import(coap_iana, [decode_type/1, encode_type/1]).
-import(coap_iana, [decode_enum/2, decode_enum/3, encode_enum/2, encode_enum/3]).

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

-include("coap_def.hrl").

%% CoAP Message Format
%%
%%  0                   1                   2                   3
%%  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
%% +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%% |Ver| T |  TKL  |      Code     |          Message ID           |
%% +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%% |   Token (if any, TKL bytes) ...                               |
%% +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%% |   Options (if any) ...                                        |
%% +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%% |1 1 1 1 1 1 1 1|    Payload (if any) ...                       |
%% +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%%
%%

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

%%--------------------------------------------------------------------
%% Decode CoAP Message
%%--------------------------------------------------------------------

% empty message only contains the 4-byte header
-spec(decode(binary()) -> coap_message()).
decode(<<?VERSION:2, Type:2, 0:4, 0:3, 0:5, MsgId:16>>) ->
    #coap_message{type=decode_type(Type), id=MsgId};

decode(<<?VERSION:2, Type:2, TKL:4, Class:3, DetailedCode:5, MsgId:16, Token:TKL/bytes, Tail/bytes>>) ->
    {Options, Payload} = decode_option_list(Tail),
    #coap_message{
        type=decode_type(Type),
        code=decode_enum(code(), {Class, DetailedCode}),
        id=MsgId,
        token=Token,
        options=Options,
        payload=Payload}.

decode_option_list(Tail) ->
    decode_option_list(Tail, 0, []).

% option parsing is based on Patrick's CoAP Message Parsing in Erlang
% https://gist.github.com/azdle/b2d477ff183b8bbb0aa0

% decode_option_list(<<>>, _LastNum, OptionList) ->
%     {OptionList, <<>>};
% decode_option_list(<<16#FF, Payload/bytes>>, _LastNum, OptionList) ->
%     {OptionList, Payload};
% decode_option_list(<<Delta:4, Len:4, Tail/bytes>>, LastNum, OptionList) ->
%     {Tail1, OptNum} = if
%         Delta =< 12 ->
%             {Tail, LastNum + Delta};
%         Delta == 13 ->
%             <<ExtOptNum, NewTail1/bytes>> = Tail,
%             {NewTail1, LastNum + ExtOptNum + 13};
%         Delta == 14 ->
%             <<ExtOptNum:16, NewTail1/bytes>> = Tail,
%             {NewTail1, LastNum + ExtOptNum + 269}
%     end,
%     {Tail2, OptLen} = if
%         Len < 13 ->
%             {Tail1, Len};
%         Len == 13 ->
%             <<ExtOptLen, NewTail2/bytes>> = Tail1,
%             {NewTail2, ExtOptLen + 13};
%         Len == 14 ->
%             <<ExtOptLen:16, NewTail2/bytes>> = Tail1,
%             {NewTail2, ExtOptLen + 269}
%     end,
%     case Tail2 of
%         <<OptVal:OptLen/bytes, NextOpt/bytes>> ->
%             decode_option_list(NextOpt, OptNum, append_option(decode_option({OptNum, OptVal}), OptionList));
%         <<>> ->
%             decode_option_list(<<>>, OptNum, append_option(decode_option({OptNum, <<>>}), OptionList))
%     end.

decode_option_list(<<>>, _, Options) ->
    {Options, <<>>};
decode_option_list(<<16#FF, Payload/binary>>, _, Options) ->
    {Options, Payload};
decode_option_list(<<Delta:4, OptLen:4, Bin/binary>>, OptNum, Options) when Delta =< 12 ->
    parse_option({OptLen, Bin}, OptNum + Delta, Options);
decode_option_list(<<13:4, OptLen:4, Delta:8, Bin/binary>>, OptNum, Options) ->
    parse_option({OptLen, Bin}, OptNum + Delta + 13, Options);
decode_option_list(<<14:4, OptLen:4, Delta:16/big-integer, Bin/binary>>, OptNum, Options) ->
    parse_option({OptLen, Bin}, OptNum + Delta + 269, Options).

parse_option({OptLen, Bin}, OptNum, Options) when OptLen =< 12 ->
    parse_next({OptLen, Bin}, OptNum, Options);
parse_option({13, <<Len:8, Bin/binary>>}, OptNum, Options) ->
    OptLen = Len + 13,
    parse_next({OptLen, Bin}, OptNum, Options);
parse_option({14, <<Len:16/big-integer, Bin/binary>>}, OptNum, Options) ->
    OptLen = Len + 269,
    parse_next({OptLen, Bin}, OptNum, Options).

parse_next({_OptLen, <<>>}, OptNum, Options) ->
    decode_option_list(<<>>, OptNum, append_option(decode_option({OptNum, <<>>}), Options));
parse_next({OptLen, Bin}, OptNum, Options) ->
    <<OptVal:OptLen/binary, Left/binary>> = Bin,
    decode_option_list(Left, OptNum, append_option(decode_option({OptNum, OptVal}), Options)).

% put options of the same id into one list
append_option({SameOptId, OptVal2}, [{SameOptId, OptVal1} | OptionList]) ->
    case is_repeatable_option(SameOptId) of
        true ->
            % we must keep the order
            [{SameOptId, lists:append(OptVal1, [OptVal2])} | OptionList];
        false ->
            throw({error, atom_to_list(SameOptId)++" is not repeatable"})
    end;
append_option({OptId2, OptVal2}, OptionList) ->
    case is_repeatable_option(OptId2) of
        true -> [{OptId2, [OptVal2]} | OptionList];
        false -> [{OptId2, OptVal2} | OptionList]
    end.

% RFC 7252
-spec decode_option({non_neg_integer(), _}) -> {coap_option(), _}.
decode_option({?OPTION_IF_MATCH, OptVal}) -> {'If-Match', OptVal};
decode_option({?OPTION_URI_HOST, OptVal}) -> {'Uri-Host', OptVal};
decode_option({?OPTION_ETAG, OptVal}) -> {'ETag', OptVal};
decode_option({?OPTION_IF_NONE_MATCH, <<>>}) -> {'If-None-Match', true};
decode_option({?OPTION_URI_PORT, OptVal}) -> {'Uri-Port', binary:decode_unsigned(OptVal)};
decode_option({?OPTION_LOCATION_PATH, OptVal}) -> {'Location-Path', OptVal};
decode_option({?OPTION_URI_PATH, OptVal}) -> {'Uri-Path', OptVal};
decode_option({?OPTION_CONTENT_FORMAT, OptVal}) ->
    Num = binary:decode_unsigned(OptVal),
    {'Content-Format', decode_enum(content_formats(), Num, Num)};
decode_option({?OPTION_MAX_AGE, OptVal}) -> {'Max-Age', binary:decode_unsigned(OptVal)};
decode_option({?OPTION_URI_QUERY, OptVal}) -> {'Uri-Query', OptVal};
decode_option({?OPTION_ACCEPT, OptVal}) -> 
    Num = binary:decode_unsigned(OptVal),
    {'Accept', decode_enum(content_formats(), Num, Num)};
    % {'Accept', binary:decode_unsigned(OptVal)};
decode_option({?OPTION_LOCATION_QUERY, OptVal}) -> {'Location-Query', OptVal};
decode_option({?OPTION_PROXY_URI, OptVal}) -> {'Proxy-Uri', OptVal};
decode_option({?OPTION_PROXY_SCHEME, OptVal}) -> {'Proxy-Scheme', OptVal};
decode_option({?OPTION_SIZE1, OptVal}) -> {'Size1', binary:decode_unsigned(OptVal)};
% RFC 7641
decode_option({?OPTION_OBSERVE, OptVal}) -> {'Observe', binary:decode_unsigned(OptVal)};
% draft-ietf-core-block-17
decode_option({?OPTION_BLOCK2, OptVal}) -> {'Block2', decode_block(OptVal)};
decode_option({?OPTION_BLOCK1, OptVal}) -> {'Block1', decode_block(OptVal)};
% unknown option
decode_option({OptNum, OptVal}) -> {OptNum, OptVal}.

decode_block(<<>>) -> decode_block1(0, 0, 0);
decode_block(<<Num:4, M:1, SizEx:3>>) -> decode_block1(Num, M, SizEx);
decode_block(<<Num:12, M:1, SizEx:3>>) -> decode_block1(Num, M, SizEx);
decode_block(<<Num:28, M:1, SizEx:3>>) -> decode_block1(Num, M, SizEx).

decode_block1(Num, M, SizEx) ->
    {Num, if M == 0 -> false; true -> true end, trunc(math:pow(2, SizEx+4))}.

%%--------------------------------------------------------------------
%% Serialize CoAP Message
%%--------------------------------------------------------------------

% empty message
-spec encode(coap_message()) -> binary().
encode(#coap_message{type=Type, code=undefined, id=MsgId}) ->
    <<?VERSION:2, (encode_type(Type)):2, 0:4, 0:3, 0:5, MsgId:16>>;
encode(#coap_message{type=Type, code=Code, id=MsgId, token=Token, options=Options, payload=Payload}) ->
    TKL = byte_size(Token),
    {Class, DetailedCode} = encode_enum(code(), Code),
    Tail = encode_option_list(Options, Payload),
    <<?VERSION:2, (encode_type(Type)):2, TKL:4, Class:3, DetailedCode:5, MsgId:16, Token:TKL/bytes, Tail/bytes>>.

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
-spec encode_option({coap_option(), _}) -> {non_neg_integer(), _}.
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
    Num = encode_enum(content_formats(), OptVal),
    {?OPTION_CONTENT_FORMAT, binary:encode_unsigned(Num)};
encode_option({'Max-Age', OptVal}) -> {?OPTION_MAX_AGE, binary:encode_unsigned(OptVal)};
encode_option({'Uri-Query', OptVal}) -> {?OPTION_URI_QUERY, OptVal};
encode_option({'Accept', OptVal}) when is_integer(OptVal) -> 
    {?OPTION_ACCEPT, binary:encode_unsigned(OptVal)};
encode_option({'Accept', OptVal}) -> 
    Num = encode_enum(content_formats(), OptVal),
    {?OPTION_ACCEPT, binary:encode_unsigned(Num)};
encode_option({'Location-Query', OptVal}) -> {?OPTION_LOCATION_QUERY, OptVal};
encode_option({'Proxy-Uri', OptVal}) -> {?OPTION_PROXY_URI, OptVal};
encode_option({'Proxy-Scheme', OptVal}) -> {?OPTION_PROXY_SCHEME, OptVal};
encode_option({'Size1', OptVal}) -> {?OPTION_SIZE1, binary:encode_unsigned(OptVal)};
% RFC 7641
encode_option({'Observe', OptVal}) -> {?OPTION_OBSERVE, binary:encode_unsigned(OptVal)};
% draft-ietf-core-block-17
encode_option({'Block2', OptVal}) -> {?OPTION_BLOCK2, encode_block(OptVal)};
encode_option({'Block1', OptVal}) -> {?OPTION_BLOCK1, encode_block(OptVal)};
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
    <<Num:28, M:1, SizEx:3>>.

is_repeatable_option('If-Match') -> true;
is_repeatable_option('ETag') -> true;
is_repeatable_option('Location-Path') -> true;
is_repeatable_option('Uri-Path') -> true;
is_repeatable_option('Uri-Query') -> true;
is_repeatable_option('Location-Query') -> true;
is_repeatable_option(_Else) -> false.

% option_encode_unsigned({Opt, undefined}) -> [];
% option_encode_unsigned({Opt, Num}) -> {Opt, binary:encode_unsigned(Num)}.

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

parse_test() ->
	MsgBin = <<64,1,45,91,183,115,101,110,115,111,114,115,4,116,101,109,112,193,2>>,
    Msg = decode(MsgBin),
    MsgBin2 = encode(Msg),
    ?assertEqual(MsgBin, MsgBin2).

% note that the options below must be sorted by the option numbers
codec_test()-> [
    test_codec(#coap_message{type='RST', id=0, options=[]}),
    test_codec(#coap_message{type='CON', code='GET', id=100,
        options=[{'Block1', {0,true,128}}, {'Observe', 1}]}),
    test_codec(#coap_message{type='NON', code='PUT', id=200, token= <<"token">>,
        options=[{'Uri-Path',[<<".well-known">>, <<"core">>]}]}),
    test_codec(#coap_message{type='NON', code={ok, 'Content'}, id=300, token= <<"token">>,
        payload= <<"<url>">>, options=[{'Content-Format', <<"application/link-format">>}, {'Uri-Path',[<<".well-known">>, <<"core">>]}]})
    ].

test_codec(Message) ->
    Message2 = encode(Message),
    Message1 = decode(Message2),
    ?assertEqual(Message, Message1).

-endif.
