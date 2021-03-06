-module(ecoap_request).

-export([ping_msg/0, method/1, path/1, query/1, accept/1, requires_ack/1]).
-export([request/2, request/3, request/4]).
-export([response/2, response/3]).
-export([ack/1, rst/1]).
-export([set_payload/2, set_payload/3, set_payload/4]).

-include("ecoap_message.hrl").

-define(DEFAULT_MAX_BLOCK_SIZE, 1024).

-type block_opt() :: {non_neg_integer(), boolean(), non_neg_integer()}.

-spec ping_msg() -> ecoap_message:coap_message().
ping_msg() ->
    % id set to 0 and will be overwritten afterwards
    #coap_message{type='CON', id=0}.

-spec path(ecoap_message:coap_message()) -> [binary()].
path(Request=#coap_message{}) ->
    ecoap_message:get_option('Uri-Path', Request, []).

-spec query(ecoap_message:coap_message()) -> [binary()].
query(Request=#coap_message{}) ->
    ecoap_message:get_option('Uri-Query', Request, []).

-spec accept(ecoap_message:coap_message()) -> undefined | integer() | binary().
accept(Request=#coap_message{}) ->
    ecoap_message:get_option('Accept', Request).

-spec method(ecoap_message:coap_message()) -> ecoap_message:coap_method().
method(#coap_message{code=Method}) when is_atom(Method) ->
    Method.

-spec requires_ack(ecoap_message:coap_message()) -> boolean().
requires_ack(#coap_message{type='CON'}) -> true;
requires_ack(#coap_message{}) -> false.

-spec request(ecoap_message:coap_type(), ecoap_message:coap_method()) -> ecoap_message:coap_message().
request(Type, Code) ->
    #coap_message{type=Type, code=Code, id=0}.

-spec request(ecoap_message:coap_type(), ecoap_message:coap_method(), ecoap_message:optionset()) -> ecoap_message:coap_message().
request(Type, Code, Options) ->
    #coap_message{type=Type, code=Code, id=0, options=Options}.

-spec request(ecoap_message:coap_type(), ecoap_message:coap_method(), ecoap_message:optionset(), binary()) -> ecoap_message:coap_message().
request(Type, Code, Options, Payload) when is_binary(Payload) ->
    set_payload(Payload, #coap_message{type=Type, code=Code, id=0, options=Options}). 

-spec ack(ecoap_message:coap_message() | non_neg_integer()) -> ecoap_message:coap_message().
ack(Request=#coap_message{}) ->
    #coap_message{type='ACK', id=Request#coap_message.id};
ack(MsgId) when is_integer(MsgId) ->
    #coap_message{type='ACK', id=MsgId}.

-spec rst(ecoap_message:coap_message() | non_neg_integer()) -> ecoap_message:coap_message().
rst(Request=#coap_message{}) ->
    #coap_message{type='RST', id=Request#coap_message.id};
rst(MsgId) when is_integer(MsgId) ->
    #coap_message{type='RST', id=MsgId}.

-spec response(ecoap_message:coap_message()) -> ecoap_message:coap_message().
response(#coap_message{type=Type, id=MsgId, token=Token}) ->
    #coap_message{type=Type, id=MsgId, token=Token}.

-spec response(undefined | ecoap_message:coap_success() | ecoap_message:coap_error(), ecoap_message:coap_message()) -> ecoap_message:coap_message().
response(Code, Request) ->
    Response = response(Request), 
    Response#coap_message{code=Code}.

-spec response(undefined | ecoap_message:coap_success() | ecoap_message:coap_error(), binary(), ecoap_message:coap_message()) -> ecoap_message:coap_message().
response(Code, Payload, Request) when is_binary(Payload) ->
    set_payload(Payload, response(Code, Request)).

-spec set_payload(binary(), ecoap_message:coap_message()) -> ecoap_message:coap_message().
set_payload(Payload, Msg) ->
	set_payload(Payload, undefined, Msg).

-spec set_payload(binary(), undefined | block_opt(), ecoap_message:coap_message()) -> ecoap_message:coap_message().
set_payload(Payload, Block, Msg) ->
    set_payload(Payload, Block, Msg, ?DEFAULT_MAX_BLOCK_SIZE).

-spec set_payload(binary(), undefined | block_opt(), ecoap_message:coap_message(), non_neg_integer()) -> ecoap_message:coap_message().
% segmentation not requested and not required
set_payload(Payload, undefined, Msg, MaxBlockSize) when byte_size(Payload) =< MaxBlockSize ->
    Msg#coap_message{payload=Payload};
% segmentation not requested, but required (late negotiation)
set_payload(Payload, undefined, Msg, MaxBlockSize) ->
    set_payload_block(Payload, {0, true, MaxBlockSize}, Msg);
% segmentation requested (early negotiation)
set_payload(Payload, Block, Msg, _) ->
	set_payload_block(Payload, Block, Msg).

-spec set_payload_block(binary(), block_opt(), ecoap_message:coap_message()) -> ecoap_message:coap_message().
set_payload_block(Content, Block, Msg=#coap_message{code=Method}) when is_atom(Method) ->
    set_payload_block(Content, 'Block1', Block, Msg);
set_payload_block(Content, Block, Msg=#coap_message{}) ->
    set_payload_block(Content, 'Block2', Block, Msg).

-spec set_payload_block(binary(), 'Block1' | 'Block2', block_opt(), ecoap_message:coap_message()) -> ecoap_message:coap_message().
set_payload_block(Content, BlockId, {Num, _, Size}, Msg=#coap_message{options=Options}) when byte_size(Content) > (Num+1)*Size ->
    Msg#coap_message{options=Options#{BlockId => {Num, true, Size}}, payload=part(Content, Num*Size, Size)};
set_payload_block(Content, BlockId, {Num, _, Size}, Msg=#coap_message{options=Options}) ->
    Msg#coap_message{options=Options#{BlockId => {Num, false, Size}}, payload=part(Content, Num*Size, byte_size(Content)-Num*Size)}.

% In case peer requested a non-existing block we just respond with an empty payload instead of crash
% e.g. request with a block number and size that indicate a block beyond the actual size of the resource
% This behaviour is the same as Californium 1.0.x/2.0.x
part(Binary, Pos, Len) when Len >= 0 ->
    binary:part(Binary, Pos, Len);
part(_, _, _) ->
    <<>>.

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

request_compose_test_() ->
    [
        ?_assertEqual(#coap_message{type='CON', code='GET', id=0},
            ecoap_request:request('CON', 'GET')),
        ?_assertEqual(#coap_message{type='CON', code='PUT', id=0, payload= <<"payload">>},
            ecoap_request:request('CON', 'PUT', #{}, <<"payload">>)),
        ?_assertEqual(#coap_message{type='CON', code='PUT', id=0, options=#{'Uri-Path' => [<<"test">>]}, payload= <<"payload">>},
            ecoap_request:request('CON', 'PUT', #{'Uri-Path' => [<<"test">>]}, <<"payload">>))
    ].

response_compose_test_() ->
    Request = #coap_message{type='CON', code='GET', id=123, token= <<"Token">>, options=#{'Uri-Path' => [<<"test">>]}},
    Payload = <<"Payload">>,
    [
        ?_assertEqual(#coap_message{type='CON', code={error, 'NotFound'}, id=123, token= <<"Token">>},
            ecoap_request:response({error, 'NotFound'}, Request)),
        ?_assertEqual(#coap_message{type='CON', code={ok, 'Content'}, id=123, token= <<"Token">>, payload=Payload},
            ecoap_request:response({ok, 'Content'}, Payload, Request))
    ].

util_test_() ->
    [
        ?_assertEqual(true, ecoap_request:requires_ack(#coap_message{type='CON'})),
        ?_assertEqual(false, ecoap_request:requires_ack(#coap_message{type='NON'})),
        ?_assertEqual(false, ecoap_request:requires_ack(#coap_message{type='ACK'})),
        ?_assertEqual(false, ecoap_request:requires_ack(#coap_message{type='RST'}))

    ].

-endif.
