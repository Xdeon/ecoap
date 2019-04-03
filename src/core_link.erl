% PALCE FOR LICIENSE
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
    try core_link_scanner:string(String) of
        {ok, TokenList, _Line} ->
            try core_link_parser:parse(TokenList) of
                {ok, Res} -> Res;
                Other -> Other
            catch C:R -> {error, {C, R}}
            end;
        Other -> 
            Other
    catch C:R -> 
        {error, {C, R}}
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

join_uri(UriList) ->
    mapjoin(fun recompose/1, "/", UriList).

recompose(Uri) ->
    uri_string:recompose(#{path => Uri}).

% sz, if, rt MUST NOT appear more than one in one link
encode_link_param({_Any, undefined}) -> undefined;
encode_link_param({ct, Value}) -> [";ct=", process_content_type(Value)];
encode_link_param({sz, Value}) -> [";sz=", process_param_value(Value)];
encode_link_param({rt, Value}) -> [";rt=\"", process_param_value(Value), "\""];
% for param that has no value
encode_link_param({Other, true}) -> [";", atom_to_list(Other)];
encode_link_param({Other, Value}) -> [";", atom_to_list(Other), "=\"", process_param_value(Value), "\""].

process_param_value(Value) when is_integer(Value) ->
    integer_to_binary(Value);
process_param_value(Value) when is_binary(Value) ->
    Value;
process_param_value(Values) when is_list(Values) ->
    mapjoin(fun process_param_value/1, " ", Values).

process_content_type(Value) when is_binary(Value) ->
    integer_to_binary(coap_iana:encode_content_format(Value));
process_content_type(Value) when is_integer(Value) ->
    integer_to_binary(Value);
process_content_type(Values) when is_list(Values) ->
    ["\"", mapjoin(fun process_content_type/1, " ", Values), "\""].

mapjoin(_, _, []) -> [];
mapjoin(Fun, Sep, [H | T]) -> [Fun(H) | join_prepend(Fun, Sep, T)].

join_prepend(_, _, []) -> [];
join_prepend(Fun, Sep, [H | T]) -> [Sep, Fun(H) | join_prepend(Fun, Sep, T)].

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
                    [{rt, <<"temperature-c">>}, {'if', <<"sensor">>}, {foo, true}, {bar, [<<"one">>, <<"two">>]}]
        }]),
    test_decode(<<"/link">>, error)
    ].

external_codec_test_() ->
    % Link below is taken from coap://californium.eclipse.org:5683/.well-known/core
    Link1 = <<"</obs>;ct=0;obs;rt=\"observe\";title=\"Observable resource which changes every 5 seconds\",</obs-pumping>;obs;rt=\"observe\";title=\"Observable resource which changes every 5 seconds\",</separate>;title=\"Resource which cannot be served immediately and which cannot be acknowledged in a piggy-backed way\",</large-create>;rt=\"block\";title=\"Large resource that can be created using POST method\",</large-create/1>;ct=0;sz=1280,</large-create/2>;ct=0;sz=1280,</seg1>;title=\"Long path resource\",</seg1/seg2>;title=\"Long path resource\",</seg1/seg2/seg3>;title=\"Long path resource\",</large-separate>;rt=\"block\";sz=1280;title=\"Large resource\",</obs-reset>,</.well-known/core>,</multi-format>;ct=\"0 41\";title=\"Resource that exists in different content formats (text/plain utf8 and application/xml)\",</path>;ct=40;title=\"Hierarchical link description entry\",</path/sub1>;title=\"Hierarchical link description sub-resource\",</path/sub2>;title=\"Hierarchical link description sub-resource\",</path/sub3>;title=\"Hierarchical link description sub-resource\",</link1>;if=\"If1\";rt=\"Type1 Type2\";title=\"Link test resource\",</link3>;if=\"foo\";rt=\"Type1 Type3\";title=\"Link test resource\",</link2>;if=\"If2\";rt=\"Type2 Type3\";title=\"Link test resource\",</obs-large>;obs;rt=\"observe\";title=\"Observable resource which changes every 5 seconds\",</validate>;ct=0;sz=17;title=\"Resource which varies\",</test>;title=\"Default test resource\",</large>;rt=\"block\";sz=1280;title=\"Large resource\",</obs-pumping-non>;obs;rt=\"observe\";title=\"Observable resource which changes every 5 seconds\",</query>;title=\"Resource accepting query parameters\",</large-post>;rt=\"block\";title=\"Handle POST with two-way blockwise transfer\",</location-query>;title=\"Perform POST transaction with responses containing several Location-Query options (CON mode)\",</obs-non>;obs;rt=\"observe\";title=\"Observable resource which changes every 5 seconds\",</large-update>;ct=0;rt=\"block\";sz=11;title=\"Large resource that can be updated using PUT method\",</shutdown>">>,
    Link2 = <<"</test>;rt=\"test\";ct=0,</validate>;rt=\"validate\";ct=0,</hello>;rt=\"Type1\";ct=0;if=\"If1\",</bl%C3%A5b%C3%A6rsyltet%C3%B8y>;rt=\"blåbærsyltetøy\";ct=0,</sink>;rt=\"sink\";ct=0,</separate>;rt=\"separate\";ct=0,</large>;rt=\"Type1 Type2\";ct=0;sz=1700;if=\"If2\",</secret>;rt=\"secret\";ct=0,</broken>;rt=\"Type2 Type1\";ct=0;if=\"If2 If1\",</weird33>;rt=\"weird33\";ct=0,</weird44>;rt=\"weird44\";ct=0,</weird55>;rt=\"weird55\";ct=0,</weird333>;rt=\"weird333\";ct=0,</weird3333>;rt=\"weird3333\";ct=0,</weird33333>;rt=\"weird33333\";ct=0,</123412341234123412341234>;rt=\"123412341234123412341234\";ct=0,</location-query>;rt=\"location-query\";ct=0,</create1>;rt=\"create1\";ct=0,</large-update>;rt=\"large-update\";ct=0,</large-create>;rt=\"large-create\";ct=0,</query>;rt=\"query\";ct=0,</seg1>;rt=\"seg1\";ct=40,</path>;rt=\"path\";ct=40,</location1>;rt=\"location1\";ct=40,</multi-format>;rt=\"multi-format\";ct=0,</3>;rt=\"3\";ct=50,</4>;rt=\"4\";ct=50,</5>;rt=\"5\";ct=50"/utf8>>,
    [?_assertEqual(encode(decode(Link1)), Link1),
    ?_assertEqual(encode(decode(Link2)), Link2)
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
