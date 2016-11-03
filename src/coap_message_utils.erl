-module(coap_message_utils).
% -export([reset/1]).
-compile([export_all]).

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
