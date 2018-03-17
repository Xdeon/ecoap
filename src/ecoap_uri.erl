-module(ecoap_uri).

-export([decode_uri/1, encode_uri/1]).

-include("ecoap.hrl").

-type uri() :: string().
-type scheme() :: atom().
-type host() :: binary().
-type path() :: [binary()].
-type query() :: [binary()].

-export_type([uri/0, scheme/0, host/0, path/0, query/0]).

-spec decode_uri(Uri) -> {Scheme, Host, PeerAddress, Path, Query} when
    Uri :: uri(),
    Scheme :: scheme(),
    Host :: host() | undefined, 
    PeerAddress :: {inet:ip_address(), inet:port_number()},
    Path :: path(),
    Query :: query().
decode_uri(Uri) ->
    {ok, {Scheme, _UserInfo, Host, PortNo, Path, Query}} =
        http_uri:parse(Uri, [{scheme_defaults, [{coap, ?DEFAULT_COAP_PORT}, {coaps, ?DEFAULT_COAPS_PORT}]}]),
   case inet:parse_address(Host) of
        {ok, PeerIP} -> 
            {Scheme, undefined, {PeerIP, PortNo}, split_path(Path), split_query(Query)};
        {error,einval} -> 
            {ok, PeerIP} = inet:getaddr(Host, inet),
            % RFC 7252 Section 6.3
            % The scheme and host are case insensitive and normally provided in lowercase
            {Scheme, list_to_binary(string:to_lower(Host)), {PeerIP, PortNo}, split_path(Path), split_query(Query)}
    end.

split_path([]) -> [];
split_path([$/]) -> [];
split_path([$/ | Path]) -> split_segments(Path, "/", []).

split_query([]) -> [];
split_query([$? | Path]) -> split_segments(Path, "&", []).

% split_segments(Path, Char, Acc) ->
%     case string:rchr(Path, Char) of
%         0 ->
%             [make_segment(Path) | Acc];
%         N when N > 0 ->
%             split_segments(string:substr(Path, 1, N-1), Char,
%                 [make_segment(string:substr(Path, N+1)) | Acc])
%     end.

split_segments(Path, Char, Acc) ->
    case string:split(Path, Char, trailing) of
        [Path] -> 
            [make_segment(Path) | Acc];
        [Path1, Path2] ->
            split_segments(Path1, Char, [make_segment(Path2) | Acc])
    end.

make_segment(Seg) ->
    list_to_binary(http_uri:decode(Seg)).

-spec encode_uri({Scheme, Host, PeerAddress, Path, Query}) -> Uri when
    Scheme :: scheme(),
    Host :: host() | undefined,
    PeerAddress :: {inet:hostname() | inet:ip_address(), inet:port_number()},
    Path :: path(),
    Query :: query(),
    Uri :: uri().
encode_uri({Scheme, Host, {PeerIP, PortNo}, Path, Query}) ->
    PathString = lists:foldl(fun(Segment, Acc) -> Acc ++ "/" ++ escape_uri(Segment) end, "", Path),
    QueryString = case Query of
        [] -> "";
        _ -> lists:foldl(fun(Segment, Acc) -> 
                [Name, Value] = binary:split(Segment, <<$=>>),
                Acc ++ escape_uri(Name) ++ "=" ++ escape_uri(Value) end, "?", Query)
    end,
    HostString = case Host of
        undefined ->
            case is_tuple(PeerIP) of
                true -> inet:ntoa(PeerIP);
                false -> PeerIP
            end;
        Else -> binary_to_list(Else)
    end,
    lists:concat([Scheme, "://", HostString, ":", PortNo, PathString, QueryString]).

% taken from http://stackoverflow.com/questions/114196/url-encode-in-erlang/12648499#12648499
escape_uri(S) ->
    escape_uri_binary(unicode:characters_to_binary(S)).
    
escape_uri_binary(<<C:8, Cs/binary>>) when C >= $a, C =< $z ->
    [C] ++ escape_uri_binary(Cs);
escape_uri_binary(<<C:8, Cs/binary>>) when C >= $A, C =< $Z ->
    [C] ++ escape_uri_binary(Cs);
escape_uri_binary(<<C:8, Cs/binary>>) when C >= $0, C =< $9 ->
    [C] ++ escape_uri_binary(Cs);
escape_uri_binary(<<C:8, Cs/binary>>) when C == $. ->
    [C] ++ escape_uri_binary(Cs);
escape_uri_binary(<<C:8, Cs/binary>>) when C == $- ->
    [C] ++ escape_uri_binary(Cs);
escape_uri_binary(<<C:8, Cs/binary>>) when C == $_ ->
    [C] ++ escape_uri_binary(Cs);
escape_uri_binary(<<C:8, Cs/binary>>) ->
    escape_byte(C) ++ escape_uri_binary(Cs);
escape_uri_binary(<<>>) ->
    "".

escape_byte(C) ->
    "%" ++ hex_octet(C).

hex_octet(N) when N =< 9 ->
    [$0 + N];
hex_octet(N) when N > 15 ->
    hex_octet(N bsr 4) ++ hex_octet(N band 15);
hex_octet(N) ->
    [N - 10 + $A].

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
