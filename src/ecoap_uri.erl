-module(ecoap_uri).

-export([decode_uri/1, encode_uri/1, get_uri_params/1, get_peer_addr/1]).
-export([default_transport/1, default_port/1]).

-define(DEFAULT_COAP_PORT, 5683).
-define(DEFAULT_COAPS_PORT, 5684).

-type uri() :: iodata().
-type scheme() :: coap | coaps.
-type host() :: binary().
-type path() :: [binary()].
-type query() :: [binary()].

-type uri_map() :: #{
    scheme := scheme(),
    host := undefined | host(),
    port := inet:port_number(),
    ip := inet:ip_address(),
    path := path(),
    'query' := query()
}.

-export_type([uri/0, scheme/0, host/0, path/0, query/0, uri_map/0]).

-spec decode_uri(ecoap_uri:uri()) -> ecoap_uri:uri_map() | uri_string:error() | {error, inet:posix()}.
decode_uri(Uri) when is_list(Uri) ->
    decode_uri(list_to_binary(Uri));
decode_uri(Uri) ->
    case parse_uri(Uri) of 
        {error, _, _}=Error -> Error;
        UriMap -> format_urimap(UriMap)
    end.

-spec parse_uri(ecoap_uri:uri()) -> uri_string:uri_map() | uri_string:error().
parse_uri(Uri) ->
    case uri_string:normalize(Uri) of
        {error, _, _}=Error -> Error;
        NormUri -> uri_string:parse(NormUri)
    end.

-spec format_urimap(uri_string:uri_map()) -> ecoap_uri:uri_map() | {error, inet:posix() | invalid_uri}.
format_urimap(UriMap0=#{host:=RawHost, scheme:=RawScheme}) ->
    case get_peer_addr(RawHost) of
        {error, Reason} ->
            {error, Reason};
        {ok, Host, IP} ->
            UriMap = dissect_pq(UriMap0),
            Scheme = scheme_to_atom(RawScheme),
            Port = maps:get(port, UriMap, default_port(Scheme)),
            UriMap#{scheme => Scheme, host => Host, port => Port, ip => IP}
    end;
format_urimap(_) ->
    {error, invalid_uri}.

-spec get_peer_addr(binary() | list() | tuple()) -> {ok, undefined | binary(), inet:ip_addres()} | {error, inet:posix()}.
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

% "/a/b/c?d=1&e=%E4%B8%8A%E6%B5%B7" -> 
% #{path => [<<"a">>, <<"b">>, <<"c">>], query => [<<"d=1">>, <<"e=上海"/utf8>>], ...}
-spec get_uri_params(ecoap_uri:uri()) -> map() | uri_string:error().
get_uri_params(Uri) when is_list(Uri) ->
    get_uri_params(list_to_binary(Uri));
get_uri_params(Uri) ->
    case parse_uri(Uri) of 
        {error, _, _}=Error -> Error;
        UriMap-> dissect_pq(UriMap)
    end.

-spec dissect_pq(map()) -> map().
dissect_pq(UriMap) ->
    Path = split_path(maps:get(path, UriMap, <<>>)),
    Query = split_query(maps:get('query', UriMap, <<>>)),
    UriMap#{path => Path, 'query' => Query}.

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

split_path(<<>>) -> [];
split_path(<<"/">>) -> [];
split_path(<<"/", Path/binary>>) -> split_and_decode_segments(Path, <<"/">>, fun cow_uri:urldecode/1);
split_path(Path) -> split_and_decode_segments(Path, <<"/">>, fun cow_uri:urldecode/1).

split_query(<<>>) -> [];
split_query(Query) -> split_and_decode_segments(Query, <<"&">>, fun cow_qs:urldecode/1).

split_and_decode_segments(Segments, SplitChar, DecodeFun) ->
    lists:map(DecodeFun, string:split(Segments, SplitChar, all)).

-spec encode_uri(ecoap_uri:uri_map()) -> ecoap_uri:uri().
encode_uri(#{scheme:=Scheme, host:=Host, port:=_, ip:=IP, path:=Path, 'query':=Query}=UriMap0) ->
    UriMap1 = UriMap0#{scheme=>atom_to_scheme(Scheme),
        host=>build_host(Host, IP),
        path=>build_path(Path)},
    UriMap2 = case build_query(Query) of
        <<>> -> maps:remove('query', UriMap1);
        Querys -> UriMap1#{'query'=>Querys}
    end,
    UriMap = maps:remove(ip, UriMap2),
    uri_string:recompose(UriMap).

build_host(undefined, PeerIP) -> 
    inet:ntoa(PeerIP);
build_host(Host, _) -> 
    binary_to_list(Host).

% since OTP23.1: for backword compatibility, produce <<>> for empty path and <<"/...">> for non-empty path
build_path(Path) -> 
    case lists:join(<<"/">>, Path) of
        [] -> <<>>;
        SubPath -> <<"/", (list_to_binary(SubPath))/binary>>
    end.

build_query(Query) ->
    list_to_binary(lists:join(<<"&">>, Query)).

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
