-module(ecoap_uri).

-export([decode_uri/1, encode_uri/1, get_path/1, get_query/1]).

-include("ecoap.hrl").

-type uri() :: string().
-type scheme() :: atom().
-type host() :: binary().
-type path() :: [binary()].
-type query() :: [binary()].

-export_type([uri/0, scheme/0, host/0, path/0, query/0]).

% -spec decode_uri(Uri) -> {Scheme, Host, PeerAddress, Path, Query} | {error, Error} when
%     Uri :: uri(),
%     Scheme :: scheme(),
%     Host :: host() | undefined, 
%     PeerAddress :: {inet:ip_address(), inet:port_number()},
%     Path :: path(),
%     Query :: query(),
%     Error :: term().
% decode_uri(Uri) ->
%     {ok, {Scheme, _UserInfo, Host, PortNo, Path, Query}} =
%         http_uri:parse(Uri, [{scheme_defaults, [{coap, ?DEFAULT_COAP_PORT}, {coaps, ?DEFAULT_COAPS_PORT}]}]),
%     case inet:parse_address(Host) of
%         {ok, PeerIP} -> 
%             {Scheme, undefined, {PeerIP, PortNo}, split_path(Path), split_query(Query)};
%         {error,einval} -> 
%             case inet:getaddr(Host, inet) of
%                 {ok, PeerIP} ->
%                 % RFC 7252 Section 6.3
%                 % The scheme and host are case insensitive and normally provided in lowercase
%                 {Scheme, list_to_binary(string:to_lower(Host)), {PeerIP, PortNo}, split_path(Path), split_query(Query)};
%                 {error, Error} ->
%                     {error, Error}
%             end
%     end.

decode_uri(Uri) when is_list(Uri) ->
    decode_uri(list_to_binary(Uri));
decode_uri(Uri) ->
    {ok, {Scheme, Host, Port, Path, Query}} = parse_uri(Uri),
    HostString = binary_to_list(Host),
    case inet:parse_address(HostString) of
        {ok, PeerIP} -> 
            {Scheme, undefined, {PeerIP, Port}, split_path(Path), split_query2(Query)};
        {error, einval} -> 
            case inet:getaddr(HostString, inet) of
                {ok, PeerIP} ->
                    {Scheme, Host, {PeerIP, Port}, split_path(Path), split_query2(Query)};
                {error, Error} ->
                    {error, Error}
            end
    end.

get_path(Uri) when is_list(Uri) ->
    get_path(list_to_binary(Uri));
get_path(<<"/", _/binary>>=Uri) ->
    case uri_string:parse(uri_string:normalize(Uri)) of
        {error, Reason, _} -> {error, Reason};
        ParsedUri -> split_path(maps:get(path, ParsedUri, <<>>))
    end;
get_path(Uri) -> 
    {error, {bad_uri, Uri}}.

get_query(Uri) when is_list(Uri) ->
    get_query(list_to_binary(Uri));
get_query(Uri) ->
    case uri_string:parse(uri_string:normalize(Uri)) of
        {error, Reason, _} -> {error, Reason};
        ParsedUri -> split_query2(maps:get(query, ParsedUri, <<>>))
    end.

parse_uri(Uri) ->
    case uri_string:parse(uri_string:normalize(Uri)) of 
        {error, Reason, _} -> {error, Reason};
        ParsedUri ->    
            Scheme = scheme_to_atom(maps:get(scheme, ParsedUri, '')),
            Host = maps:get(host, ParsedUri, undefined),
            Port = maps:get(port, ParsedUri, default_port(Scheme)),
            Path = maps:get(path, ParsedUri, <<>>),
            Query = maps:get(query, ParsedUri, <<>>),
            {ok, {Scheme, Host, Port, Path, Query}}
    end.

scheme_to_atom(<<"coap">>) ->
    coap;
scheme_to_atom(<<"coaps">>) ->
    coaps;
scheme_to_atom('') ->
    throw({error, no_scheme});
scheme_to_atom(Scheme) ->
    throw({error, {bad_scheme, Scheme}}).

atom_to_scheme(coap) ->
    <<"coap">>;
atom_to_scheme(coaps) ->
    <<"coaps">>;
atom_to_scheme(Scheme) when is_atom(Scheme) ->
    throw({error, {bad_scheme, Scheme}});
atom_to_scheme(_) ->
    throw({error, scheme_must_be_atom}).

default_port(coap) -> ?DEFAULT_COAP_PORT;
default_port(coaps) -> ?DEFAULT_COAPS_PORT.

split_query2(<<>>) -> [];
split_query2(Path) -> split_segments(Path, <<"&">>).

split_path(<<>>) -> [];
split_path(<<"/">>) -> [];
split_path(<<"/", Path/binary>>) -> split_segments(Path, <<"/">>).

% split_query([]) -> [];
% split_query([$? | Path]) -> split_segments(Path, "&", []).

% split_segments(Path, Char, Acc) ->
%     case string:rchr(Path, Char) of
%         0 ->
%             [make_segment(Path) | Acc];
%         N when N > 0 ->
%             split_segments(string:substr(Path, 1, N-1), Char,
%                 [make_segment(string:substr(Path, N+1)) | Acc])
%     end.

split_segments(Path, Char) ->
    lists:map(fun make_segment/1, string:split(Path, Char, all)).
 
make_segment(Seg) ->
    http_uri:decode(Seg).

encode_uri({Scheme, Host, {PeerIP, Port}, Path, Query}) -> 
    Uri0 = #{scheme=>atom_to_scheme(Scheme), 
        host=>build_host(Host, PeerIP), 
        port=>Port, 
        path=>build_path(Path)},
    Uri = case build_query(Query) of 
        [] ->  Uri0;
        QueryList -> Uri0#{query=>QueryList}
    end,
    uri_string:recompose(Uri).

build_host(undefined, PeerIP) -> 
    inet:ntoa(PeerIP);
build_host(Host, _) -> 
    binary_to_list(Host).

build_path(Path) -> 
    ["/", assemble_segments(Path, fun http_uri:encode/1, "/")].

build_query(Query) ->
    lists:join("&", Query).

assemble_segments(Segments, TransFun, Char) ->
    % apply TransFun on each Segment and then join the list with Char
    lists:join(Char, lists:map(TransFun, Segments)).

% -spec encode_uri({Scheme, Host, PeerAddress, Path, Query}) -> Uri when
%     Scheme :: scheme(),
%     Host :: host() | undefined,
%     PeerAddress :: {inet:hostname() | inet:ip_address(), inet:port_number()},
%     Path :: path(),
%     Query :: query(),
%     Uri :: uri().
% encode_uri({Scheme, Host, {PeerIP, PortNo}, Path, Query}) ->
%     PathString = ["/", assemble_segments(Path, fun escape_uri/1, "/")],
%     QueryString = case Query of
%         [] -> [];
%         _ -> 
%             ["?", assemble_segments(Query, 
%                 fun(Segment) ->
%                     case binary:split(Segment, <<$=>>) of
%                         [Segment] ->
%                             escape_uri(Segment);
%                         [Name, Value] ->
%                             [escape_uri(Name), "=", escape_uri(Value)]
%                     end 
%                 end, "&")]
%     end,
%     HostString = case Host of
%         undefined ->
%             case is_tuple(PeerIP) of
%                 true -> inet:ntoa(PeerIP);
%                 false -> PeerIP
%             end;
%         Else -> binary_to_list(Else)
%     end,
%     lists:concat([Scheme, "://", HostString, ":", PortNo, lists:flatten(PathString), lists:flatten(QueryString)]).

% taken from http://stackoverflow.com/questions/114196/url-encode-in-erlang/12648499#12648499
% escape_uri(S) ->
%     escape_uri_binary(unicode:characters_to_binary(S)).
    
% escape_uri_binary(<<C:8, Cs/binary>>) when C >= $a, C =< $z ->
%     [C] ++ escape_uri_binary(Cs);
% escape_uri_binary(<<C:8, Cs/binary>>) when C >= $A, C =< $Z ->
%     [C] ++ escape_uri_binary(Cs);
% escape_uri_binary(<<C:8, Cs/binary>>) when C >= $0, C =< $9 ->
%     [C] ++ escape_uri_binary(Cs);
% escape_uri_binary(<<C:8, Cs/binary>>) when C == $. ->
%     [C] ++ escape_uri_binary(Cs);
% escape_uri_binary(<<C:8, Cs/binary>>) when C == $- ->
%     [C] ++ escape_uri_binary(Cs);
% escape_uri_binary(<<C:8, Cs/binary>>) when C == $_ ->
%     [C] ++ escape_uri_binary(Cs);
% escape_uri_binary(<<C:8, Cs/binary>>) ->
%     escape_byte(C) ++ escape_uri_binary(Cs);
% escape_uri_binary(<<>>) ->
%     "".

% escape_byte(C) ->
%     "%" ++ hex_octet(C).

% hex_octet(N) when N =< 9 ->
%     [$0 + N];
% hex_octet(N) when N > 15 ->
%     hex_octet(N bsr 4) ++ hex_octet(N band 15);
% hex_octet(N) ->
%     [N - 10 + $A].

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

uri_test_() ->
    [
        ?_assertEqual({coap, undefined, {{192,168,0,1}, ?DEFAULT_COAP_PORT}, [], []}, ecoap_uri:decode_uri("coap://192.168.0.1")),
        % tests modified based on gen_coap coap_client
        ?_assertEqual({coap, <<"localhost">>, {{127,0,0,1},?DEFAULT_COAP_PORT},[], []}, ecoap_uri:decode_uri("coap://localhost")),
        ?_assertEqual({coap, <<"localhost">>, {{127,0,0,1},1234},[], []}, ecoap_uri:decode_uri("coap://localhost:1234")),
        ?_assertEqual({coap, <<"localhost">>, {{127,0,0,1},?DEFAULT_COAP_PORT},[], []}, ecoap_uri:decode_uri("coap://localhost/")),
        ?_assertEqual({coap, <<"localhost">>, {{127,0,0,1},1234},[], []}, ecoap_uri:decode_uri("coap://localhost:1234/")),
        ?_assertEqual({coaps, <<"localhost">>, {{127,0,0,1},?DEFAULT_COAPS_PORT},[], []}, ecoap_uri:decode_uri("coaps://localhost")),
        ?_assertEqual({coaps, <<"localhost">>, {{127,0,0,1},1234},[], []}, ecoap_uri:decode_uri("coaps://localhost:1234")),
        ?_assertEqual({coaps, <<"localhost">>, {{127,0,0,1},?DEFAULT_COAPS_PORT},[], []}, ecoap_uri:decode_uri("coaps://localhost/")),
        ?_assertEqual({coaps, <<"localhost">>, {{127,0,0,1},1234},[], []}, ecoap_uri:decode_uri("coaps://localhost:1234/")),
        ?_assertEqual({coap, <<"localhost">>, {{127,0,0,1},?DEFAULT_COAP_PORT},[<<"/">>], []}, ecoap_uri:decode_uri("coap://localhost/%2F")),
        % from RFC 7252, Section 6.3
        % the following three URIs are equivalent
        ?_assertEqual({coap, <<"localhost">>, {{127,0,0,1},5683},[<<"~sensors">>, <<"temp.xml">>], []},
            ecoap_uri:decode_uri("coap://localhost:5683/~sensors/temp.xml")),
        ?_assertEqual({coap, <<"localhost">>, {{127,0,0,1},?DEFAULT_COAP_PORT},[<<"~sensors">>, <<"temp.xml">>], []},
            ecoap_uri:decode_uri("coap://LOCALHOST/%7Esensors/temp.xml")),
        ?_assertEqual({coap, <<"localhost">>, {{127,0,0,1},?DEFAULT_COAP_PORT},[<<"~sensors">>, <<"temp.xml">>], []},
            ecoap_uri:decode_uri("coap://LOCALHOST/%7esensors/temp.xml")),
        % from RFC 7252, Appendix B
        ?_assertEqual({coap, <<"localhost">>, {{127,0,0,1},61616},[<<>>, <<"/">>, <<>>, <<>>], [<<"//">>,<<"?&">>]},
            ecoap_uri:decode_uri("coap://localhost:61616//%2F//?%2F%2F&?%26")),
        % unicode decode & encode test
        ?_assertEqual({coap, <<"localhost">>, {{127,0,0,1}, ?DEFAULT_COAP_PORT}, [<<"non-ascii-path-äöü"/utf8>>], [<<"non-ascii-query=äöü"/utf8>>]},
            ecoap_uri:decode_uri("coap://localhost:5683/non-ascii-path-%C3%A4%C3%B6%C3%BC?non-ascii-query=%C3%A4%C3%B6%C3%BC")),
        ?_assertEqual("coap://192.168.0.1:5683/non-ascii-path-%C3%A4%C3%B6%C3%BC?non-ascii-query=%C3%A4%C3%B6%C3%BC",
            ecoap_uri:encode_uri({coap, undefined, {{192,168,0,1}, ?DEFAULT_COAP_PORT}, [<<"non-ascii-path-äöü"/utf8>>], [<<"non-ascii-query=äöü"/utf8>>]})),
        ?_assertEqual("coap://example.com:5683/%E3%83%86%E3%82%B9%E3%83%88", 
            ecoap_uri:encode_uri({coap, <<"example.com">>, {{192,168,0,1}, ?DEFAULT_COAP_PORT}, [<<"テスト"/utf8>>], []}))
    ].

-endif.
