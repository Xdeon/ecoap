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

-type coap_uri() :: {'absolute' | 'rootless', [binary()], [coap_uri_param()]}.
-type coap_uri_param() :: {atom(), binary() | [binary()]}.

-export_type([coap_uri/0]).
-export_type([coap_uri_param/0]).

-spec decode(binary() | list()) -> coap_uri() | {error, term()}.
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

-spec encode([coap_uri_param()]) -> binary().
encode(LinkList) ->
    list_to_binary(lists:foldl(
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

join_uri(Uri) ->
    lists:join("/", lists:map(fun(Seg) -> http_uri:encode(Seg) end, Uri)).

% sz, if, rt MUST NOT appear more than one in one link
encode_link_param({_Any, undefined}) -> undefined;
encode_link_param({ct, Value}) -> [";ct=", content_type_to_int(Value)];
encode_link_param({sz, Value}) -> [";sz=", param_value_to_list(Value)];
encode_link_param({rt, Value}) -> [";rt=\"", param_value_to_list(Value), "\""];
% for param that has no value
encode_link_param({Other, <<>>}) -> [";", atom_to_list(Other)];
encode_link_param({Other, Value}) -> [";", atom_to_list(Other), "=\"", param_value_to_list(Value), "\""].

param_value_to_list(Value) when is_integer(Value) ->
    integer_to_list(Value);
param_value_to_list(Value) when is_binary(Value) ->
    binary_to_list(Value);
param_value_to_list(Values) when is_list(Values) ->
    lists:join(" ", [param_value_to_list(Val) || Val <- Values]). 

content_type_to_int(Value) when is_binary(Value) ->
    integer_to_list(coap_iana:encode_content_format(Value));
content_type_to_int(Value) when is_integer(Value) ->
    integer_to_list(Value);
content_type_to_int(Values) when is_list(Values) ->
    ["\"", lists:join(" ", [content_type_to_int(Val) || Val <- Values]), "\""].

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

codec_test_() -> 
    [
    ?_assertEqual(<<"<link>;ct=0;sz=5">>, encode([{rootless, [<<"link">>], [{ct, <<"text/plain">>}, {sz, 5}]}])),
    test_decode(<<"<link>">>, [{rootless, [<<"link">>], []}]),
    test_decode(<<"</link1>;par=\"val\",<link2>;par=\"val\";par2=\"val2\"">>,
        [{absolute, [<<"link1">>], [{par, <<"val">>}]}, {rootless, [<<"link2">>], [{par, <<"val">>}, {par2, <<"val2">>}]}]),
    test_decode(<<"</sensors/temp>;rt=\"temperature-c\";if=\"sensor\";foo;bar=\"one two\"">>, 
        [{absolute, [<<"sensors">>, <<"temp">>], 
                    [{rt, <<"temperature-c">>}, {'if', <<"sensor">>}, {foo, <<>>}, {bar, [<<"one">>, <<"two">>]}]
        }]),
    test_decode(<<"/link">>, error)
    ].

external_codec_test_() ->
    % Link below is taken from coap://californium.eclipse.org:5683/.well-known/core
    Link = <<"</obs>;ct=0;obs;rt=\"observe\";title=\"Observable resource which changes every 5 seconds\",</obs-pumping>;obs;rt=\"observe\";title=\"Observable resource which changes every 5 seconds\",</separate>;title=\"Resource which cannot be served immediately and which cannot be acknowledged in a piggy-backed way\",</large-create>;rt=\"block\";title=\"Large resource that can be created using POST method\",</large-create/1>;ct=0;sz=1280,</large-create/2>;ct=0;sz=1280,</seg1>;title=\"Long path resource\",</seg1/seg2>;title=\"Long path resource\",</seg1/seg2/seg3>;title=\"Long path resource\",</large-separate>;rt=\"block\";sz=1280;title=\"Large resource\",</obs-reset>,</.well-known/core>,</multi-format>;ct=\"0 41\";title=\"Resource that exists in different content formats (text/plain utf8 and application/xml)\",</path>;ct=40;title=\"Hierarchical link description entry\",</path/sub1>;title=\"Hierarchical link description sub-resource\",</path/sub2>;title=\"Hierarchical link description sub-resource\",</path/sub3>;title=\"Hierarchical link description sub-resource\",</link1>;if=\"If1\";rt=\"Type1 Type2\";title=\"Link test resource\",</link3>;if=\"foo\";rt=\"Type1 Type3\";title=\"Link test resource\",</link2>;if=\"If2\";rt=\"Type2 Type3\";title=\"Link test resource\",</obs-large>;obs;rt=\"observe\";title=\"Observable resource which changes every 5 seconds\",</validate>;ct=0;sz=17;title=\"Resource which varies\",</test>;title=\"Default test resource\",</large>;rt=\"block\";sz=1280;title=\"Large resource\",</obs-pumping-non>;obs;rt=\"observe\";title=\"Observable resource which changes every 5 seconds\",</query>;title=\"Resource accepting query parameters\",</large-post>;rt=\"block\";title=\"Handle POST with two-way blockwise transfer\",</location-query>;title=\"Perform POST transaction with responses containing several Location-Query options (CON mode)\",</obs-non>;obs;rt=\"observe\";title=\"Observable resource which changes every 5 seconds\",</large-update>;ct=0;rt=\"block\";sz=11;title=\"Large resource that can be updated using PUT method\",</shutdown>">>,
    [?_assertEqual(encode(decode(Link)), Link)].

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
