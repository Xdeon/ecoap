%
% The contents of this file are subject to the Mozilla Public License
% Version 1.1 (the "License"); you may not use this file except in
% compliance with the License. You may obtain a copy of the License at
% http://www.mozilla.org/MPL/
%
% Copyright (c) 2015 Petr Gotthard <petr.gotthard@centrum.cz>
%

% encoding and decoding for the CoRE link format, see RFC 6690
-module(core_link).

-export([decode/1, encode/1]).

-type coap_uri() :: {'absolute', [binary()], [coap_uri_param()]}.
-type coap_uri_param() :: {atom(), binary() | [binary()]}.

-export_type([coap_uri/0]).
-export_type([coap_uri_param/0]).

-spec decode(binary() | list()) -> coap_uri() | {error, any()}.
decode(Binary) when is_binary(Binary) ->
    decode(binary_to_list(Binary));
decode(String) ->
    % the parser is auto-generated using leex and yecc
    case catch core_link_scanner:string(String) of
        {ok, TokenList, _Line} ->
            case catch core_link_parser:parse(TokenList) of
                {ok, Res} -> Res;
                Err -> {error, Err}
            end;
        Err -> {error, Err}
    end.

-spec encode([coap_uri_param()]) -> list().
encode(LinkList) ->
    lists:flatten(lists:foldl(
        fun (Link, []) -> encode_link_value(Link);
            (Link, Str) -> [Str, ",", encode_link_value(Link)]
        end, [], LinkList)).

encode_link_value({UriType, UriList, Attrs}) ->
    [encode_link_uri(UriType, UriList), encode_link_params(Attrs)].

encode_link_params(Attrs) ->
    lists:reverse(lists:foldl(
        fun(Attr, Acc) ->
            case encode_link_param(Attr) of
                undefined -> Acc;
                Val -> [Val|Acc]
            end
        end, [], Attrs)).

encode_link_uri(absolute, UriList) -> ["</", join_uri(UriList), ">"];
encode_link_uri(rootless, UriList) -> ["<", join_uri(UriList), ">"].

join_uri([]) -> [];
join_uri([Seg]) ->
    http_uri:encode(binary_to_list(Seg));
join_uri([Seg|Uri]) ->
    http_uri:encode(binary_to_list(Seg))++"/"++join_uri(Uri).

% sz, if, rt MUST NOT appear more than one in one link
encode_link_param({_Any, undefined}) -> undefined;
encode_link_param({ct, Value}) -> [";ct=", content_type_to_int(Value)];
encode_link_param({sz, Value}) -> [";sz=", integer_to_list(Value)];
encode_link_param({rt, Value}) -> [";rt=\"", param_value_to_list(Value), "\""];
% for param that has no value
encode_link_param({Other, <<>>}) -> [";", atom_to_list(Other)];
encode_link_param({Other, Value}) -> [";", atom_to_list(Other), "=\"", param_value_to_list(Value), "\""].

param_value_to_list(Value) when is_binary(Value) ->
    binary_to_list(Value);

param_value_to_list(Values) when is_list(Values) ->
    binary_to_list(process_param_value(Values, <<>>)).

process_param_value([], Acc) -> Acc;
process_param_value([H], Acc) -> <<Acc/binary, H/binary>>;
process_param_value([H|Rest], Acc) -> process_param_value(Rest, <<Acc/binary, H/binary, " ">>).    

content_type_to_int(Value) when is_binary(Value) ->
    case coap_iana:encode_content_format(Value) of
        Num when is_integer(Num) -> integer_to_list(Num);
        _ -> ["\"",  binary_to_list(Value), "\""]
    end;
content_type_to_int(Value) when is_integer(Value) ->
    integer_to_list(Value).

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

codec_test_() -> 
    [
    ?_assertEqual("<link>;ct=0;sz=5", encode([{rootless, [<<"link">>], [{ct, <<"text/plain">>}, {sz, 5}]}])),
    test_decode("<link>", [{rootless, [<<"link">>], []}]),
    test_decode("</link1>;par=\"val\",<link2>;par=\"val\";par2=\"val2\"",
        [{absolute, [<<"link1">>], [{par, <<"val">>}]}, {rootless, [<<"link2">>], [{par, <<"val">>}, {par2, <<"val2">>}]}]),
    test_decode("</sensors/temp>;rt=\"temperature-c\";if=\"sensor\";foo;bar=\"one two\"", 
        [{absolute, [<<"sensors">>, <<"temp">>], 
                    [{rt, <<"temperature-c">>}, {'if', <<"sensor">>}, {foo, <<>>}, {bar, [<<"one">>, <<"two">>]}]
        }]),
    test_decode("/link", error)
    ].

test_decode(String, error) ->
    Struct2 = decode(String),
    ?_assertMatch({error, _}, Struct2);

test_decode(String, Struct) ->
    Struct2 = decode(String),
    [?_assertEqual(Struct, Struct2),
    % try reverse encoding of the decoded structure
    ?_assertEqual(String, encode(Struct2))].

-endif.
% end of file
