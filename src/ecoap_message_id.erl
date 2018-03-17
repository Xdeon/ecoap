-module(ecoap_message_id).
-export([first_mid/0, next_mid/1]).

-define(MAX_MESSAGE_ID, 65535). % 16-bit number

-spec first_mid() -> coap_message:msg_id().
first_mid() ->
    _ = rand:seed(exs1024),
    rand:uniform(?MAX_MESSAGE_ID).

% a MsgId must not be reused within EXCHANGE_LIFETIME
% no check is done for now that whether a MsgId can be safely reused
% if that feature is expected, we can have a grouped MsgId tracker 
% which separate MsgId space into several groups and let one group represent all MsgIds within that range
% and only track the expire time of the last used MsgId of every group, e.g., an array of size of number of groups 
% with each element for expire time of one group, so that effectively save memory cost
% downside is
% 1. unable to track MsgId precisely since the expire time of a group is determined by the last MsgId of that group
% 2. have to do with situation of no available MsgId
% idea comes from:
% https://github.com/eclipse/californium/issues/323
% https://github.com/eclipse/californium/pull/271
% https://github.com/eclipse/californium/pull/328

-spec next_mid(coap_message:msg_id()) -> coap_message:msg_id().
next_mid(MsgId) ->
    if
        MsgId < ?MAX_MESSAGE_ID -> MsgId + 1;
        true -> 1 % or 0?
    end.