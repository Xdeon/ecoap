-module(coap_message_utils).

-export([msg_id/1, request/2, request/3, request/4, ack/1, response/1, response/2, response/3]).

-export([set_opt/3, set_type/2, set_code/2, set_payload/2, set_content/2, set_content/3, 
         get_content/1, get_option/2, get_option/3, has_option/2, remove_option/2]).

-define(MAX_BLOCK_SIZE, 1024).

-include("coap_def.hrl").

-type block_opt() :: {non_neg_integer(), boolean(), non_neg_integer()}.

-spec request(coap_type(), coap_method()) -> coap_message().
request(Type, Code) ->
    request(Type, Code, <<>>, []).

-spec request(coap_type(), coap_method(), coap_content()|binary()) -> coap_message().
request(Type, Code, Payload) ->
    request(Type, Code, Payload, []).

-spec request(coap_type(), coap_method(), coap_content()|binary(), [tuple()]) -> coap_message().
request(Type, Code, Payload, Options) when is_binary(Payload) ->
    #coap_message{type=Type, code=Code, payload=Payload, options=Options};
request(Type, Code, Content=#coap_content{}, Options) ->
    set_content(Content,
        #coap_message{type=Type, code=Code, options=Options}).

-spec ack(coap_message()) -> coap_message().
ack(Request=#coap_message{}) ->
    #coap_message{
        type='ACK',
        id=Request#coap_message.id
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

-spec response(undefined|coap_success()|coap_error(), coap_message()) -> coap_message().
response(Code, Request) ->
    set_code(Code,
        response(Request)).

-spec response(undefined|coap_success()|coap_error(), coap_content()|binary()|list(), coap_message()) -> coap_message().
response(Code, Payload, Request) ->
    set_code(Code,
        set_payload(Payload,
            response(Request))).

% shortcut function for reset generation
-spec msg_id(binary()|coap_message()) -> non_neg_integer().
msg_id(<<_:16, MsgId:16, _Tail/bytes>>) -> MsgId;
msg_id(#coap_message{id=MsgId}) -> MsgId.

-spec get_option(coap_option(), [tuple()]) -> term().
get_option(Option, OptionList) ->
    get_option(Option, OptionList, undefined).

-spec get_option(coap_option(), [tuple()], term()) -> term().
get_option(Option, OptionList, Default) ->
    case lists:keyfind(Option, 1, OptionList) of
        {_, Value} -> Value;
        _ -> Default
    end.

-spec has_option(coap_option(), [tuple()]) -> boolean().
has_option(Option, OptionList) ->
    lists:keymember(Option, 1, OptionList).

-spec remove_option(coap_option(), [tuple()]) -> [tuple()].
remove_option(Option, OptionList) ->
    lists:keydelete(Option, 1, OptionList).

-spec set_type(coap_type(), coap_message()) -> coap_message().
set_type(Type, Msg) ->
    Msg#coap_message{
        type=Type
    }.

-spec set_code(coap_code(), coap_message()) -> coap_message().
set_code(Code, Msg) ->
    Msg#coap_message{
        code=Code
    }.

-spec set_opt(coap_option(), any(), coap_message()) -> coap_message().
% omit option for its default value
set_opt(_, undefined, Msg) -> Msg;
set_opt('Max-Age', ?DEFAULT_MAX_AGE, Msg) -> Msg;
set_opt('ETag', ETag, Msg) -> set_option('ETag', [ETag], Msg);
set_opt(Option, Value, Msg) -> set_option(Option, Value, Msg).

set_option(Option, Value, Msg=#coap_message{options=Options}) ->
    Msg#coap_message{
        options=lists:keystore(Option, 1, Options, {Option, Value})
    }.

-spec set_payload(coap_content()|binary()|list(), coap_message()) -> coap_message().
set_payload(Payload=#coap_content{}, Msg) ->
    set_content(Payload, undefined, Msg);
set_payload(Payload, Msg) when is_binary(Payload) ->
    Msg#coap_message{
        payload=Payload
    };
set_payload(Payload, Msg) when is_list(Payload) ->
    Msg#coap_message{
        payload=list_to_binary(Payload)
    }.

-spec get_content(coap_message()) -> coap_content().
get_content(#coap_message{options=Options, payload=Payload}) ->
    #coap_content{
        etag = case get_option('ETag', Options) of
                   [ETag] -> ETag;
                   _Other -> undefined
               end,
        max_age = get_option('Max-Age', Options),
        format = get_option('Content-Format', Options),
        payload = Payload}.

-spec set_content(coap_content(), coap_message()) -> coap_message().
set_content(Content, Msg) ->
    set_content(Content, undefined, Msg).

-spec set_content(coap_content(), undefined|block_opt(), coap_message()) -> coap_message().
% segmentation not requested and not required
set_content(#coap_content{etag=ETag, max_age=MaxAge, format=Format, payload=Payload}, undefined, Msg)
        when byte_size(Payload) =< ?MAX_BLOCK_SIZE ->
    set_opt('ETag', ETag,
        set_opt('Max-Age', MaxAge,
            set_opt('Content-Format', Format,
                set_payload(Payload, Msg))));
% segmentation not requested, but required (late negotiation)
set_content(Content, undefined, Msg) ->
    set_content(Content, {0, true, ?MAX_BLOCK_SIZE}, Msg);
% segmentation requested (early negotiation)
set_content(#coap_content{etag=ETag, max_age=MaxAge, format=Format, payload=Payload}, Block, Msg) ->
    set_opt('ETag', ETag,
        set_opt('Max-Age', MaxAge,
            set_opt('Content-Format', Format,
                set_payload_block(Payload, Block, Msg)))).

-spec set_payload_block(binary(), block_opt(), coap_message()) -> coap_message().
set_payload_block(Content, Block, Msg=#coap_message{code=Code}) when is_atom(Code) ->
    set_payload_block(Content, 'Block1', Block, Msg);
set_payload_block(Content, Block, Msg=#coap_message{}) ->
    set_payload_block(Content, 'Block2', Block, Msg).

-spec set_payload_block(binary(), 'Block1'|'Block2', block_opt(), coap_message()) -> coap_message().
set_payload_block(Content, BlockId, {Num, _, Size}, Msg) when byte_size(Content) > (Num+1)*Size ->
    set_opt(BlockId, {Num, true, Size},
        set_payload(binary:part(Content, Num*Size, Size), Msg));
set_payload_block(Content, BlockId, {Num, _, Size}, Msg) ->
    set_opt(BlockId, {Num, false, Size},
        set_payload(binary:part(Content, Num*Size, byte_size(Content)-Num*Size), Msg)).
