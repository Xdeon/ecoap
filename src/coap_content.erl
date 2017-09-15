-module(coap_content).
-export([new/0]).
-export([get_etag/1, set_etag/2, get_max_age/1, set_max_age/2, 
		 get_format/1, set_format/2, get_options/1, set_options/2, 
		 get_payload/1, set_payload/2]).
-export([get_content/1, get_content/2, set_content/2, set_content/3]).

-include("ecoap.hrl").

-record(coap_content, {
	etag = undefined :: undefined | binary(),
	max_age = ?DEFAULT_MAX_AGE :: non_neg_integer(),
	format = undefined :: undefined | binary() | non_neg_integer(),
	options = #{} :: coap_message:optionset(),
	payload = <<>> :: binary()
}).

-opaque coap_content() :: #coap_content{}.

-type block_opt() :: {non_neg_integer(), boolean(), non_neg_integer()}.

-export_type([coap_content/0]).

-spec new() -> coap_content().
new() -> #coap_content{}.

-spec get_etag(coap_content()) -> undefined | binary().
get_etag(#coap_content{etag=ETag}) -> ETag.

-spec set_etag(binary(), coap_content()) -> coap_content().
set_etag(ETag, Content) -> Content#coap_content{etag=ETag}.

-spec get_max_age(coap_content()) -> non_neg_integer().
get_max_age(#coap_content{max_age=MaxAge}) -> MaxAge.

-spec set_max_age(non_neg_integer(), coap_content()) -> coap_content().
set_max_age(MaxAge, Content) -> Content#coap_content{max_age=MaxAge}.

-spec get_format(coap_content()) -> undefined | binary() | non_neg_integer().
get_format(#coap_content{format=Format}) -> Format.

-spec set_format(binary() | non_neg_integer(), coap_content()) -> coap_content().
set_format(Format, Content) -> Content#coap_content{format=Format}.

-spec get_options(coap_content()) -> coap_message:optionset().
get_options(#coap_content{options=Options}) -> Options.

-spec set_options(coap_message:optionset(), coap_content()) -> coap_content().
set_options(Options, Content) -> Content#coap_content{options=Options}.

-spec get_payload(coap_content()) -> binary().
get_payload(#coap_content{payload=Payload}) -> Payload.

-spec set_payload(binary(), coap_content()) -> coap_content().
set_payload(Payload, Content) -> Content#coap_content{payload=Payload}.

-spec get_content(coap_message:coap_message()) -> coap_content().
get_content(Msg) ->
    get_content(Msg, default).

-spec get_content(coap_message:coap_message(), default | extended) -> coap_content().
get_content(#{options:=Options, payload:=Payload}, Extended) ->
    #coap_content{
        etag = case coap_message:get_option('ETag', Options) of
                   [ETag] -> ETag;
                   _ -> undefined
            end,
        max_age = coap_message:get_option('Max-Age', Options, ?DEFAULT_MAX_AGE),
        format = coap_message:get_option('Content-Format', Options),
        options = case Extended of
                    default -> #{};
                    extended -> get_extra_options(Options)
            end,
        payload = Payload}.

get_extra_options(Options) ->
    UsedOptions = ['ETag', 'Max-Age', 'Content-Format', 
                    'Uri-Path', 'Uri-Query', 'Block1', 
                    'Block2', 'Observe', 'If-Match', 'If-None-Match'],
    maps:without(UsedOptions, Options).

-spec set_content(coap_content(), coap_message:coap_message()) -> coap_message:coap_message().
set_content(Content, Msg) ->
    set_content(Content, undefined, Msg).

-spec set_content(coap_content(), undefined | block_opt(), coap_message:coap_message()) -> coap_message:coap_message().
% segmentation not requested and not required
set_content(Content=#coap_content{payload=Payload}, undefined, Msg) when byte_size(Payload) =< ?MAX_BLOCK_SIZE ->
    set_content_helper(Content, coap_message:set_payload(Payload, Msg));
% segmentation not requested, but required (late negotiation)
set_content(Content, undefined, Msg) ->
    set_content(Content, {0, true, ?MAX_BLOCK_SIZE}, Msg);
% segmentation requested (early negotiation)
set_content(Content=#coap_content{payload=Payload}, Block, Msg) ->
    set_content_helper(Content, set_payload_block(Payload, Block, Msg)).

% any abundant option for ETag, Max-Age and Content-Format in options will be replaced by its counterpart filed in coap_content
set_content_helper(#coap_content{etag=ETag, max_age=MaxAge, format=Format, options=Options}, Msg) ->
	coap_message:set_option('ETag', etag(ETag),
        coap_message:set_option('Max-Age', MaxAge,
            coap_message:set_option('Content-Format', Format, 
                coap_message:set_options(Options, Msg)))).

etag(undefined) -> undefined;
etag(ETag) -> [ETag].

-spec set_payload_block(binary(), block_opt(), coap_message:coap_message()) -> coap_message:coap_message().
set_payload_block(Content, Block, Msg=#{code:=Code}) when is_atom(Code) ->
    set_payload_block(Content, 'Block1', Block, Msg);
set_payload_block(Content, Block, Msg) ->
    set_payload_block(Content, 'Block2', Block, Msg).

-spec set_payload_block(binary(), 'Block1' | 'Block2', block_opt(), coap_message:coap_message()) -> coap_message:coap_message().
set_payload_block(Content, BlockId, {Num, _, Size}, Msg) when byte_size(Content) > (Num+1)*Size ->
    coap_message:set_option(BlockId, {Num, true, Size},
        coap_message:set_payload(part(Content, Num*Size, Size), Msg));
set_payload_block(Content, BlockId, {Num, _, Size}, Msg) ->
    coap_message:set_option(BlockId, {Num, false, Size},
        coap_message:set_payload(part(Content, Num*Size, byte_size(Content)-Num*Size), Msg)).

% In case peer requested a non-existing block we just respond with an empty payload instead of crash
% e.g. request with a block number and size that indicate a block beyond the actual size of the resource
% This behaviour is the same as Californium 1.0.x/2.0.x
part(Binary, Pos, Len) when Len >= 0 ->
    binary:part(Binary, Pos, Len);
part(_, _, _) ->
    <<>>.