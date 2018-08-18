-module(resource_directory).

-export([coap_discover/1, coap_get/5]).

-behaviour(ecoap_handler).

coap_discover(_Prefix) ->
    % [{absolute, Prefix, []}].
    [].

coap_get(_EpID, _Prefix, [], Query, _Request) ->
    Links = core_link:encode(filter(ecoap_registry:get_links(), Query)),
    Options = #{'ETag' => [binary:part(crypto:hash(sha, Links), {0,4})], 'Content-Format' => <<"application/link-format">>},
    {ok, coap_content:new(Links, Options)};
coap_get(_EpID, _Prefix, _Else, _Query, _Request) ->
    {error, 'NotFound'}.

% uri-query processing

% filter(Links, []) ->
%     Links;
% filter(Links, [Search | Query]) ->
%     filter(
%         case binary:split(Search, <<$=>>) of
%             [Name0, Value0] ->
%                 Name = list_to_atom(binary_to_list(Name0)),
%                 Value = wildcard_value(Value0),
%                 lists:filter(
%                     fun (Link) -> match_link(Link, Name, Value) end,
%                     Links);
%             _Else ->
%                 Links
%         end,
%         Query).

filter(Links, Querys) ->
    lists:foldl(fun(Query, Acc) ->
        case parse_query(Query) of
            {error, bad_query} -> Acc;
            {error, not_existing_query} -> [];
            {Name, Value} -> lists:filter(fun(Link) -> match_link(Link, Name, Value) end, Acc)
        end
    end, Links, Querys).

parse_query(Query) ->
    case uri_string:dissect_query(Query) of
        [{Name0, Value0}] ->
            try list_to_existing_atom(binary_to_list(Name0)) of
                Name -> 
                    Value = wildcard_value(Value0),
                    {Name, Value}
            catch error:badarg ->
                {error, not_existing_query}
            end;
        _ -> {error, bad_query}
    end.

wildcard_value(<<>>) ->
    {global, <<>>};
wildcard_value(Value) ->
    case binary:last(Value) of
        $* -> {prefix, binary:part(Value, 0, byte_size(Value)-1)};
        _Else -> {global, Value}
    end.

match_link({_Type, _Uri, Attrs}, Name, Value) ->
    lists:any(
        fun(AttrVal) ->
            % AttrVal can be integer, binary, or a list of integer/binary
            match_attrval(AttrVal, Value)
        end,
        proplists:get_all_values(Name, Attrs)).

match_attrval([_|_]=AttrVal, Value) ->
    lists:any(fun(Elem) -> match(Elem, Value) end, AttrVal);
match_attrval(AttrVal, Value) ->
    match(AttrVal, Value).

match(AttrVal, Value) ->
    AttrVal2 = convert_attrval(AttrVal),
    case Value of
        {prefix, Val} -> binary:part(AttrVal2, 0, byte_size(Val)) =:= Val;
        {global, Val} -> AttrVal2 =:= Val
    end.

convert_attrval(AttrVal) when is_integer(AttrVal) -> integer_to_binary(AttrVal);
convert_attrval(AttrVal) -> AttrVal.

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

attribute_query_test_() ->
    Link = [{absolute, [<<"sensor">>], [{title, <<"Sensor Index">>}]},
           {absolute, [<<"sensors">>, <<"temp">>], [{rt, <<"temperature-c">>}, {'if', <<"sensor">>}, {foo, true}, {bar, [<<"one">>, <<"two">>]}]},
           {absolute, [<<"sensors">>, <<"light">>], [{rt, [<<"light-lux">>, <<"core.sen-light">>]}, {'if', <<"sensor">>}, {foo, true}]}],
    Sensors = <<"</sensors/temp>;rt=\"temperature-c\";if=\"sensor\";foo;bar=\"one two\"">>,
    [?_assertEqual(Sensors, core_link:encode(filter(Link, make_query("bar=one&if=sensor")))),
    ?_assertEqual(Sensors, core_link:encode(filter(Link, make_query("bar=one&foo")))),
    ?_assertEqual(Sensors, core_link:encode(filter(Link, make_query("if=sensor&bar=one")))),
    ?_assertEqual(Sensors, core_link:encode(filter(Link, make_query("foo&bar=one")))),
    ?_assertEqual(Sensors, core_link:encode(filter(Link, make_query("bar=one&bar=two")))),
    ?_assertEqual(Sensors, core_link:encode(filter(Link, make_query("bar=one*")))),
    ?_assertEqual(<<>>, core_link:encode(filter(Link, make_query("bar=one&bar=three")))),
    % test for not qualified query
    ?_assertEqual(core_link:encode(Link), core_link:encode(filter(Link, make_query("bar&")))),
    % test unknown atoms for safety
    ?_assertEqual(<<>>, core_link:encode(filter(Link, make_query("what=one&thefuck=three"))))
    ]. 

make_query(Query) ->
    binary:split(list_to_binary(Query), <<$&>>).

-endif.
