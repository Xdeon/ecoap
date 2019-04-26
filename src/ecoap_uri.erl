-module(ecoap_uri).

-export([decode_uri/1, encode_uri/1, get_uri_parms/1, get_peer_addr/1]).
-export([default_transport/1, default_port/1]).

-include("ecoap.hrl").

-type uri() :: iodata().
-type scheme() :: coap | coaps.
-type host() :: binary().
-type path() :: [binary()].
-type 'query'() :: [binary()].

-type uri_map() :: #{
    scheme := scheme(),
    host := undefined | host(),
    port := inet:port_number(),
    ip := inet:ip_address(),
    path := path(),
    'query' := 'query'()
}.

-export_type([uri/0, scheme/0, host/0, path/0, 'query'/0, uri_map/0]).

-spec decode_uri(Uri) -> UriMap | {error, _, _} | {error, _} when
    Uri :: uri(),
    UriMap :: uri_map().
decode_uri(Uri) when is_list(Uri) ->
    decode_uri(list_to_binary(Uri));
decode_uri(Uri) ->
    case parse_uri(Uri) of 
        {error, _, _} = Error -> 
            Error;
        UriMap -> 
            transform_urimap(UriMap)
    end.

parse_uri(Uri) ->
    uri_string:parse(uri_string:normalize(Uri)).

transform_urimap(UriMap0=#{host:=RawHost, scheme:=RawScheme}) ->
    case get_peer_addr(RawHost) of
        {error, Reason} ->
            {error, Reason};
        {ok, Host, IP} ->
            UriMap = get_uri_parms(UriMap0),
            Scheme = scheme_to_atom(RawScheme),
            Port = maps:get(port, UriMap, default_port(Scheme)),
            UriMap#{scheme => Scheme, host => Host, port => Port, ip => IP}
    end;
transform_urimap(_) ->
    {error, invalid_uri}.

-spec get_peer_addr(binary() | list() | tuple()) -> {ok, undefined | binary(), inet:ip_addres()} | {error, term()}.
get_peer_addr(Host) when is_binary(Host) ->
    get_peer_addr(binary_to_list(Host));
get_peer_addr(Host) ->
    % first check if it is an ip address like "127.0.0.1"
    case inet:parse_address(Host) of
        {ok, PeerIP} -> 
            {ok, undefined, PeerIP};
        {error, einval} -> 
            % then check if it is an ip addrss like {127,0,0,1} or a domain like "coap.me"
            case inet:getaddr(Host, inet) of
                {ok, PeerIP} when is_list(Host) ->
                    {ok, list_to_binary(Host), PeerIP};
                {ok, PeerIP} ->
                    {ok, undefined, PeerIP};
                {error, Reason} ->
                    {error, Reason}
            end
    end. 

-spec get_uri_parms(map()) -> map();
                   (list() | binary()) -> map() | {error, _, _}.
get_uri_parms(UriMap) when is_map(UriMap) ->
    Path = split_path(maps:get(path, UriMap, <<>>)),
    Query = split_query(maps:get('query', UriMap, <<>>)),
    UriMap#{path => Path, 'query' => Query};
get_uri_parms("/" ++ _ = Uri) ->
    get_uri_parms(list_to_binary(Uri));
get_uri_parms(Uri) when is_list(Uri) ->
    get_uri_parms(list_to_binary("/" ++ Uri));
get_uri_parms(Uri) ->
    case parse_uri(Uri) of
        {error, _, _} = Error -> Error;
        UriMap -> get_uri_parms(UriMap)
    end.

scheme_to_atom(<<"coap">>) ->
    coap;
scheme_to_atom(<<"coaps">>) ->
    coaps.

atom_to_scheme(coap) ->
    <<"coap">>;
atom_to_scheme(coaps) ->
    <<"coaps">>.

default_port(coap) -> ?DEFAULT_COAP_PORT;
default_port(coaps) -> ?DEFAULT_COAPS_PORT.

default_transport(?DEFAULT_COAPS_PORT) -> dtls;
default_transport(_) -> udp.

split_query(<<>>) -> [];
split_query(Path) -> split_segments(Path, <<"&">>).

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

-spec encode_uri(uri_map()) -> uri().
encode_uri(#{scheme:=Scheme, host:=Host, port:=_, ip:=IP, path:=Path, 'query':=Query}=UriMap0) ->
    UriMap1 = UriMap0#{scheme=>atom_to_scheme(Scheme),
        host=>build_host(Host, IP),
        path=>build_path(Path)},
    UriMap2 = case build_query(Query) of
        [] -> maps:remove('query', UriMap1);
        QueryList -> UriMap1#{'query'=>QueryList}
    end,
    UriMap = maps:remove(ip, UriMap2),
    uri_string:recompose(UriMap).

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

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

uri_test_() ->
    [
        ?_assertEqual(#{scheme=>coap, host=>undefined, ip=>{192,168,0,1}, port=>?DEFAULT_COAP_PORT, path=>[], 'query'=>[]}, ecoap_uri:decode_uri("coap://192.168.0.1")),
        % tests modified based on gen_coap coap_client
        ?_assertEqual(#{scheme=>coap, host=> <<"localhost">>, ip=>{127,0,0,1}, port=>?DEFAULT_COAP_PORT, path=>[], 'query'=>[]}, ecoap_uri:decode_uri("coap://localhost")),
        ?_assertEqual(#{scheme=>coap, host=> <<"localhost">>, ip=>{127,0,0,1}, port=>1234, path=>[], 'query'=>[]}, ecoap_uri:decode_uri("coap://localhost:1234")),
        ?_assertEqual(#{scheme=>coap, host=> <<"localhost">>, ip=>{127,0,0,1}, port=>?DEFAULT_COAP_PORT, path=>[], 'query'=>[]}, ecoap_uri:decode_uri("coap://localhost/")),
        ?_assertEqual(#{scheme=>coap, host=> <<"localhost">>, ip=>{127,0,0,1}, port=>1234, path=>[], 'query'=>[]}, ecoap_uri:decode_uri("coap://localhost:1234/")),
        ?_assertEqual(#{scheme=>coaps, host=> <<"localhost">>, ip=>{127,0,0,1}, port=>?DEFAULT_COAPS_PORT, path=>[], 'query'=>[]}, ecoap_uri:decode_uri("coaps://localhost")),
        ?_assertEqual(#{scheme=>coaps, host=> <<"localhost">>, ip=>{127,0,0,1}, port=>1234, path=>[], 'query'=>[]}, ecoap_uri:decode_uri("coaps://localhost:1234")),
        ?_assertEqual(#{scheme=>coaps, host=> <<"localhost">>, ip=>{127,0,0,1}, port=>?DEFAULT_COAPS_PORT, path=>[], 'query'=>[]}, ecoap_uri:decode_uri("coaps://localhost/")),
        ?_assertEqual(#{scheme=>coaps, host=> <<"localhost">>, ip=>{127,0,0,1}, port=>1234, path=>[], 'query'=>[]}, ecoap_uri:decode_uri("coaps://localhost:1234/")),
        ?_assertEqual(#{scheme=>coap, host=> <<"localhost">>, ip=>{127,0,0,1}, port=>?DEFAULT_COAP_PORT, path=>[<<"/">>], 'query'=>[]}, ecoap_uri:decode_uri("coap://localhost/%2F")),
        % from RFC 7252, Section 6.3
        % the following three URIs are equivalent
        ?_assertEqual(#{scheme=>coap, host=> <<"localhost">>, ip=>{127,0,0,1}, port=>?DEFAULT_COAP_PORT, path=>[<<"~sensors">>, <<"temp.xml">>], 'query'=>[]},
            ecoap_uri:decode_uri("coap://localhost:5683/~sensors/temp.xml")),
        ?_assertEqual(#{scheme=>coap, host=> <<"localhost">>, ip=>{127,0,0,1}, port=>?DEFAULT_COAP_PORT, path=>[<<"~sensors">>, <<"temp.xml">>], 'query'=>[]},
            ecoap_uri:decode_uri("coap://LOCALHOST/%7Esensors/temp.xml")),
        ?_assertEqual(#{scheme=>coap, host=> <<"localhost">>, ip=>{127,0,0,1}, port=>?DEFAULT_COAP_PORT, path=>[<<"~sensors">>, <<"temp.xml">>], 'query'=>[]},
            ecoap_uri:decode_uri("coap://LOCALHOST/%7esensors/temp.xml")),
        % from RFC 7252, Appendix B
        ?_assertEqual(#{scheme=>coap, host=> <<"localhost">>, ip=>{127,0,0,1}, port=>61616, path=>[<<>>, <<"/">>, <<>>, <<>>], 'query'=>[<<"//">>,<<"?&">>]},
            ecoap_uri:decode_uri("coap://localhost:61616//%2F//?%2F%2F&?%26")),
        % unicode decode & encode test
        ?_assertEqual(#{scheme=>coap, host=> <<"localhost">>, ip=>{127,0,0,1}, port=>?DEFAULT_COAP_PORT, path=>[<<"non-ascii-path-äöü"/utf8>>], 'query'=>[<<"non-ascii-query=äöü"/utf8>>]},
            ecoap_uri:decode_uri("coap://localhost:5683/non-ascii-path-%C3%A4%C3%B6%C3%BC?non-ascii-query=%C3%A4%C3%B6%C3%BC")),
        ?_assertEqual("coap://192.168.0.1:5683/non-ascii-path-%C3%A4%C3%B6%C3%BC?non-ascii-query=%C3%A4%C3%B6%C3%BC",
            ecoap_uri:encode_uri(#{scheme=>coap, host=>undefined, ip=>{192,168,0,1}, port=>?DEFAULT_COAP_PORT, path=>[<<"non-ascii-path-äöü"/utf8>>], 'query'=>[<<"non-ascii-query=äöü"/utf8>>]})),
        ?_assertEqual("coap://example.com:5683/%E3%83%86%E3%82%B9%E3%83%88", 
            ecoap_uri:encode_uri(#{scheme=>coap, host=> <<"example.com">>, ip=>{192,168,0,1}, port=>?DEFAULT_COAP_PORT, path=>[<<"テスト"/utf8>>], 'query'=>[]}))
    ].

-endif.
