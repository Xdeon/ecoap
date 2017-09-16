-module(ecoap_request).
-export([requires_ack/1]).
-export([request/2, request/3, request/4]).
-export([response/2, response/3]).
-export([ack/1, rst/1]).
-export([set_payload/2, set_payload/3]).

-include("ecoap.hrl").

-type block_opt() :: {non_neg_integer(), boolean(), non_neg_integer()}.

-spec requires_ack(coap_message:coap_message()) -> boolean().
requires_ack(#{type := 'CON'}) -> true;
requires_ack(#{type := 'NON'}) -> false.

-spec request(coap_message:coap_type(), coap_message:coap_method()) -> coap_message:coap_message().
request(Type, Code) ->
    request(Type, Code, #{}, <<>>).

-spec request(coap_message:coap_type(), coap_message:coap_method(), coap_message:optionset()) -> coap_message:coap_message().
request(Type, Code, Options) ->
    request(Type, Code, Options, <<>>).

-spec request(coap_message:coap_type(), coap_message:coap_method(), coap_message:optionset(), binary()) -> coap_message:coap_message().
request(Type, Code, Options, Payload) when is_binary(Payload) ->
    coap_message:set_payload(Payload,
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

-spec response(undefined | coap_message:coap_success() | coap_message:coap_error(), coap_message:coap_message()) -> coap_message:coap_message().
response(Code, Request) ->
    (response(Request))#{code:=Code}.

-spec response(undefined | coap_message:coap_success() | coap_message:coap_error(), binary(), coap_message:coap_message()) -> coap_message:coap_message().
response(Code, Payload, Request) when is_binary(Payload) ->
   set_code(Code,
        set_payload(Payload,
            response(Request))).

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

set_code(Code, Msg) ->
	coap_message:set_code(Code, Msg).

set_payload(Payload, Msg) ->
	set_payload(Payload, undefined, Msg).

% segmentation not requested and not required
set_payload(Payload, undefined, Msg) when byte_size(Payload) =< ?MAX_BLOCK_SIZE ->
	coap_message:set_payload(Payload, Msg);
% segmentation not requested, but required (late negotiation)
set_payload(Payload, undefined, Msg) ->
	set_payload(Payload, {0, true, ?MAX_BLOCK_SIZE}, Msg);
% segmentation requested (early negotiation)
set_payload(Payload, Block, Msg) ->
	set_payload_block(Payload, Block, Msg).

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