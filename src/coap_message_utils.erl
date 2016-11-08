-module(coap_message_utils).

-export([msg_id/1]).
-export([request/2, request/3, request/4, ack/1, response/1, response/2, response/3]).
-export([set/3, set_payload/2, get_content/1, set_content/2, set_content/3]).

-include("coap_def.hrl").

% shortcut function for reset generation
-spec msg_id(binary() | coap_message()) -> non_neg_integer().
msg_id(<<_:16, MsgId:16, _Tail/bytes>>) -> MsgId;
msg_id(#coap_message{id=MsgId}) -> MsgId.

% reset(MsgId) ->
% 	#coap_message{type='RST', id=MsgId}.

% msg_type(#coap_message{type=Type}) -> Type.

% msg_token(#coap_message{token=Token}) -> Token.

% msg_code(#coap_message{code=Code}) -> Code.

% set_msg_id(Message, MsgId) -> Message#coap_message{id=MsgId}.

% set_msg_token(Message, Token) -> Message#coap_message{token=Token}.

%
% The contents of this file are subject to the Mozilla Public License
% Version 1.1 (the "License"); you may not use this file except in
% compliance with the License. You may obtain a copy of the License at
% http://www.mozilla.org/MPL/
%
% Copyright (c) 2015 Petr Gotthard <petr.gotthard@centrum.cz>
%

% convenience functions for message construction

request(Type, Code) ->
    request(Type, Code, <<>>, []).

request(Type, Code, Payload) ->
    request(Type, Code, Payload, []).

request(Type, Code, Payload, Options) when is_binary(Payload) ->
    #coap_message{type=Type, code=Code, payload=Payload, options=Options};
request(Type, Code, Content=#coap_content{}, Options) ->
    set_content(Content,
        #coap_message{type=Type, code=Code, options=Options}).


ack(Request=#coap_message{}) ->
    #coap_message{
        type='ACK',
        id=Request#coap_message.id
    }.

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

response(Method, Request) ->
    set_method(Method,
        response(Request)).

response(Method, Payload, Request) ->
    set_method(Method,
        set_payload(Payload,
            response(Request))).

get_content(#coap_message{options=Options, payload=Payload}) ->
    #coap_content{
        etag = case proplists:get_value('ETag', Options) of
                   [ETag] -> ETag;
                   _Other -> undefined
               end,
        max_age = proplists:get_value('Max-Age', Options),
        format = proplists:get_value('Content-Format', Options),
        payload = Payload}.

% omit option for its default value
set('Max-Age', ?DEFAULT_MAX_AGE, Msg) -> Msg;
% set non-default value
set(Option, Value, Msg=#coap_message{options=Options}) ->
    Msg#coap_message{
        options=[{Option, Value}|Options]
    }.

set_method(Method, Msg) ->
    Msg#coap_message{
        code=Method
    }.

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

set_content(Content, Msg) ->
    set_content(Content, undefined, Msg).

% segmentation not requested and not required
set_content(#coap_content{etag=ETag, max_age=MaxAge, format=Format, payload=Payload}, undefined, Msg)
        when byte_size(Payload) =< ?MAX_BLOCK_SIZE ->
    set('ETag', [ETag],
        set('Max-Age', MaxAge,
            set('Content-Format', Format,
                set_payload(Payload, Msg))));
% segmentation not requested, but required (late negotiation)
set_content(Content, undefined, Msg) ->
    set_content(Content, {0, true, ?MAX_BLOCK_SIZE}, Msg);
% segmentation requested (early negotiation)
set_content(#coap_content{etag=ETag, max_age=MaxAge, format=Format, payload=Payload}, Block, Msg) ->
    set('ETag', [ETag],
        set('Max-Age', MaxAge,
            set('Content-Format', Format,
                set_payload_block(Payload, Block, Msg)))).

set_payload_block(Content, Block, Msg=#coap_message{code=Method}) when is_atom(Method) ->
    set_payload_block(Content, 'Block1', Block, Msg);
set_payload_block(Content, Block, Msg=#coap_message{}) ->
    set_payload_block(Content, 'Block2', Block, Msg).

set_payload_block(Content, BlockId, {Num, _, Size}, Msg) when byte_size(Content) > (Num+1)*Size ->
    set(BlockId, {Num, true, Size},
        set_payload(binary:part(Content, Num*Size, Size), Msg));
set_payload_block(Content, BlockId, {Num, _, Size}, Msg) ->
    set(BlockId, {Num, false, Size},
        set_payload(binary:part(Content, Num*Size, byte_size(Content)-Num*Size), Msg)).

% end of file
