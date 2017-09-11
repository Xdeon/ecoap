-module(ecoap_utils).

-export([
    % getters of coap_message()
    get_type/1, get_code/1, get_id/1, get_token/1, get_option/2, get_option/3, get_payload/1,
    % setters of coap_message()
    set_type/2, set_code/2, set_id/2, set_token/2, set_option/3, set_payload/2,
    % other utility functions for options
    set_options/2, add_option/3, add_options/2, has_option/2, remove_option/2,
    % getter and setter of coap_content
    get_content/1, get_content/2, set_content/2, set_content/3,
    % other utility functions
    requires_ack/1, request/2, request/3, request/4, ack/1, rst/1, response/1, response/2, response/3,
    get_extra_options/1,
    decode_uri/1, encode_uri/1
    ]).

-include_lib("ecoap_common/include/coap_def.hrl").
-include("ecoap.hrl").

-type block_opt() :: {non_neg_integer(), boolean(), non_neg_integer()}.

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

-spec get_type(coap_message()) -> coap_type().
get_type(#coap_message{type=Type}) -> Type.

-spec set_type(coap_type(), coap_message()) -> coap_message().
set_type(Type, Msg) ->
    Msg#coap_message{
        type=Type
    }.

-spec get_code(coap_message()) -> undefined | coap_code().
get_code(#coap_message{code=Code}) -> Code.

-spec set_code(coap_code(), coap_message()) -> coap_message().
set_code(Code, Msg) ->
    Msg#coap_message{
        code=Code
    }.

% shortcut function for reset generation
-spec get_id(binary() | coap_message()) -> msg_id().
get_id(<<_:16, MsgId:16, _Tail/bytes>>) -> MsgId;
get_id(#coap_message{id=MsgId}) -> MsgId.

-spec set_id(msg_id(), coap_message()) -> coap_message().
set_id(MsgId, Msg) ->
    Msg#coap_message{
        id=MsgId
    }.

-spec get_token(coap_message()) -> binary().
get_token(#coap_message{token=Token}) -> Token.

-spec set_token(binary(), coap_message()) -> coap_message().
set_token(Token, Msg) ->
    Msg#coap_message{
        token=Token
    }.

-spec get_option(coap_option(), coap_message() | optionset()) -> term().
get_option(Option, Source) ->
    get_option(Option, Source, undefined).

-spec get_option(coap_option(), coap_message() | optionset(), term()) -> term().
get_option(Option, #coap_message{options=Options}, Default) ->
    get_option_helper(Option, Options, Default);
get_option(Option, Options, Default) ->
    get_option_helper(Option, Options, Default).

get_option_helper(Option, Options, Default) ->
    maps:get(Option, Options, Default).

-spec set_option(coap_option(), any(), coap_message()) -> coap_message().
set_option(Option, Value, Msg=#coap_message{options=Options}) ->
    Msg#coap_message{
        options=add_option(Option, Value, Options)
    }.

-spec set_options(optionset(), coap_message()) -> coap_message().
set_options(Options, Msg) when map_size(Options) =:= 0 -> 
    Msg;
set_options(Options2, Msg=#coap_message{options=Options1}) ->
   Msg#coap_message{options=add_options(Options1, Options2)}.

-spec add_option(coap_option(), any(), optionset()) -> optionset().
% omit option for its default value
add_option(_, [], Options) -> Options;
add_option(_, undefined, Options) -> Options;
add_option('Max-Age', ?DEFAULT_MAX_AGE, Options) -> Options;
add_option('Uri-Port', ?DEFAULT_COAP_PORT, Options) -> Options;
add_option('Uri-Port', ?DEFAULT_COAPS_PORT, Options) -> Options;
add_option(Option, Value, Options) -> Options#{Option => Value}.

-spec add_options(optionset(), optionset()) -> optionset().
add_options(Options1, Options2) ->
    maps:merge(Options1, Options2).

-spec has_option(coap_option(), coap_message() | optionset()) -> boolean().
has_option(Option, #coap_message{options=Options}) ->
    has_option_helper(Option, Options);
has_option(Option, Options) ->
    has_option_helper(Option, Options).

has_option_helper(Option, Options) ->
    maps:is_key(Option, Options).

-spec remove_option(coap_option(), Source) -> Source when Source :: coap_message() | optionset().
remove_option(Option, Msg=#coap_message{options=Options}) ->
    Msg#coap_message{options=remove_option_helper(Option, Options)};
remove_option(Option, Options) ->
    remove_option_helper(Option, Options).

remove_option_helper(Option, Options) ->
    maps:remove(Option, Options).

-spec get_payload(coap_message()) -> binary().
get_payload(#coap_message{payload=Payload}) -> Payload.

-spec set_payload(binary(), coap_message()) -> coap_message().
set_payload(Payload, Msg) ->
    Msg#coap_message{
        payload=Payload
    }.

-spec requires_ack(coap_message()) -> boolean().
requires_ack(#coap_message{type='CON'}) -> true;
requires_ack(#coap_message{type='NON'}) -> false.

-spec request(coap_type(), coap_method()) -> coap_message().
request(Type, Code) ->
    request(Type, Code, <<>>, #{}).

-spec request(coap_type(), coap_method(), coap_content() | binary()) -> coap_message().
request(Type, Code, Payload) ->
    request(Type, Code, Payload, #{}).

-spec request(coap_type(), coap_method(), coap_content() | binary(), optionset()) -> coap_message().
request(Type, Code, Content=#coap_content{}, Options) ->
    set_content(Content,
        #coap_message{type=Type, code=Code, options=Options});
request(Type, Code, Payload, Options) when is_binary(Payload) ->
    set_payload(Payload,
        #coap_message{type=Type, code=Code, options=Options}).

-spec ack(coap_message() | non_neg_integer()) -> coap_message().
ack(Request=#coap_message{}) ->
    #coap_message{
        type='ACK',
        id=Request#coap_message.id
    };
ack(MsgId) ->
    #coap_message{
        type='ACK', 
        id=MsgId
    }.

-spec rst(coap_message() | non_neg_integer()) -> coap_message().
rst(Request=#coap_message{}) ->
    #coap_message{
        type='RST',
        id=Request#coap_message.id
    }; 
rst(MsgId) ->
    #coap_message{
        type='RST', 
        id=MsgId
    }.

-spec response(coap_message()) -> coap_message().
response(Request=#coap_message{type='NON'}) ->
    #coap_message{
        type='NON',
        token=Request#coap_message.token
    };
response(Request=#coap_message{type='CON'}) ->
    #coap_message{
        type='CON',
        id=Request#coap_message.id,
        token=Request#coap_message.token
    }.

-spec response(undefined | coap_success() | coap_error(), coap_message()) -> coap_message().
response(Code, Request) ->
    set_code(Code,
        response(Request)).

-spec response(undefined | coap_success() | coap_error(), coap_content() | binary(), coap_message()) -> coap_message().
response(Code, Payload=#coap_content{}, Request) ->
    set_code(Code,
        set_content(Payload,
            response(Request)));
response(Code, Payload, Request) when is_binary(Payload) ->
    set_code(Code,
        set_payload(Payload,
            response(Request))).

-spec get_extra_options(coap_message() | optionset()) -> optionset().
get_extra_options(#coap_message{options=Options}) ->
    get_extra_options_helper(Options);
get_extra_options(Options) ->
    get_extra_options_helper(Options).

get_extra_options_helper(Options) ->
    UsedOptions = ['ETag', 'Max-Age', 'Content-Format', 
                    'Uri-Path', 'Uri-Query', 'Block1', 
                    'Block2', 'Observe', 'If-Match', 'If-None-Match'],
    maps:without(UsedOptions, Options).

-spec get_content(coap_message()) -> coap_content().
get_content(Msg) ->
    get_content(Msg, default).

-spec get_content(coap_message(), default | extended) -> coap_content().
get_content(#coap_message{options=Options, payload=Payload}, Extended) ->
    #coap_content{
        etag = case get_option('ETag', Options) of
                   [ETag] -> ETag;
                   _Other -> undefined
            end,
        max_age = get_option('Max-Age', Options, ?DEFAULT_MAX_AGE),
        format = get_option('Content-Format', Options),
        options = case Extended of
                    default -> #{};
                    extended -> get_extra_options_helper(Options)
            end,
        payload = Payload}.

-spec set_content(coap_content(), coap_message()) -> coap_message().
set_content(Content, Msg) ->
    set_content(Content, undefined, Msg).

-spec set_content(coap_content(), undefined | block_opt(), coap_message()) -> coap_message().
% segmentation not requested and not required
set_content(Content=#coap_content{payload=Payload}, undefined, Msg) when byte_size(Payload) =< ?MAX_BLOCK_SIZE ->
    set_content_helper(Content, set_payload(Payload, Msg));
% segmentation not requested, but required (late negotiation)
set_content(Content, undefined, Msg) ->
    set_content(Content, {0, true, ?MAX_BLOCK_SIZE}, Msg);
% segmentation requested (early negotiation)
set_content(Content=#coap_content{payload=Payload}, Block, Msg) ->
    set_content_helper(Content, set_payload_block(Payload, Block, Msg)).

% any abundant option for ETag, Max-Age and Content-Format in options will be replaced by its counterpart filed in coap_content
set_content_helper(#coap_content{etag=ETag, max_age=MaxAge, format=Format, options=Options}, Msg) ->
    set_option('ETag', case ETag of undefined -> undefined; Else -> [Else] end,
        set_option('Max-Age', MaxAge,
            set_option('Content-Format', Format, 
                set_options(Options, Msg)))).

-spec set_payload_block(binary(), block_opt(), coap_message()) -> coap_message().
set_payload_block(Content, Block, Msg=#coap_message{code=Code}) when is_atom(Code) ->
    set_payload_block(Content, 'Block1', Block, Msg);
set_payload_block(Content, Block, Msg=#coap_message{}) ->
    set_payload_block(Content, 'Block2', Block, Msg).

-spec set_payload_block(binary(), 'Block1' | 'Block2', block_opt(), coap_message()) -> coap_message().
set_payload_block(Content, BlockId, {Num, _, Size}, Msg) when byte_size(Content) > (Num+1)*Size ->
    set_option(BlockId, {Num, true, Size},
        set_payload(part(Content, Num*Size, Size), Msg));
set_payload_block(Content, BlockId, {Num, _, Size}, Msg) ->
    set_option(BlockId, {Num, false, Size},
        set_payload(part(Content, Num*Size, byte_size(Content)-Num*Size), Msg)).

% In case peer requested a non-existing block we just respond with an empty payload instead of crash
% e.g. request with a block number and size that indicate a block beyond the actual size of the resource
% This behaviour is the same as Californium 1.0.x/2.0.x
part(Binary, Pos, Len) when Len >= 0 ->
    binary:part(Binary, Pos, Len);
part(_, _, _) ->
    <<>>.
