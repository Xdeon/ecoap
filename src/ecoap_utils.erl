-module(ecoap_utils).

-export([
    requires_ack/1, request/2, request/3, request/4, ack/1, rst/1, response/1, response/2, response/3,
    decode_uri/1, encode_uri/1
    ]).

-include("ecoap.hrl").

-spec decode_uri(string()) -> {atom(), binary() | undefined, {inet:ip_address(), inet:port_number()}, [binary()], [binary()]}.
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

-spec encode_uri({atom(), binary() | undefined, {inet:hostname() | inet:ip_address(), inet:port_number()}, [binary()], [binary()]}) -> string().
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

-spec requires_ack(coap_message:coap_message()) -> boolean().
requires_ack(#{type := 'CON'}) -> true;
requires_ack(#{type := 'NON'}) -> false.

-spec request(coap_message:coap_type(), coap_message:coap_method()) -> coap_message:coap_message().
request(Type, Code) ->
    request(Type, Code, <<>>, #{}).

-spec request(coap_message:coap_type(), coap_message:coap_method(), coap_content:coap_content() | binary()) -> coap_message:coap_message().
request(Type, Code, Payload) ->
    request(Type, Code, Payload, #{}).

-spec request(coap_message:coap_type(), coap_message:coap_method(), coap_content:coap_content() | binary(), coap_message:optionset()) -> coap_message:coap_message().
request(Type, Code, Payload, Options) when is_binary(Payload) ->
    coap_message:set_payload(Payload,
        (coap_message:new())#{type:=Type, code:=Code, options:=Options});
request(Type, Code, Content, Options) ->
    coap_content:set_content(Content,
        (coap_message:new())#{type:=Type, code:=Code, options:=Options}).

-spec ack(coap_message:coap_message() | non_neg_integer()) -> coap_message:coap_message().
ack(#{id := MsgId}) -> 
    (coap_message:new())#{type:='ACK', id:=MsgId};
ack(MsgId) ->
    (coap_message:new())#{type:='ACK', id:=MsgId}.

-spec rst(coap_message:coap_message() | non_neg_integer()) -> coap_message:coap_message().
rst(#{id := MsgId}) -> 
    (coap_message:new())#{type:='RST', id:=MsgId};
rst(MsgId) -> 
    (coap_message:new())#{type:='RST', id:=MsgId}.

-spec response(coap_message:coap_message()) -> coap_message:coap_message().
response(#{type:='NON', token:=Token}) ->
    (coap_message:new())#{
        type:='NON',
        token:=Token
    };
response(#{type:='CON', id:=MsgId, token:=Token}) ->
    (coap_message:new())#{
        type:='CON',
        id:=MsgId,
        token:=Token
    }.

-spec response(undefined | coap_message:coap_success() | coap_message:coap_error(), coap_message:coap_message()) -> coap_message:coap_message().
response(Code, Request) ->
    (response(Request))#{code:=Code}.

-spec response(undefined | coap_message:coap_success() | coap_message:coap_error(), coap_content:coap_content() | binary(), coap_message:coap_message()) -> coap_message:coap_message().
response(Code, Payload, Request) when is_binary(Payload) ->
    coap_message:set_code(Code,
        coap_message:set_payload(Payload,
            response(Request)));
response(Code, Payload, Request) ->
    coap_message:set_code(Code,
        coap_content:set_content(Payload,
            response(Request))).