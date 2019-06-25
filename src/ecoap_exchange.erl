-module(ecoap_exchange).

%% API
-export([init/2, received/3, send/3, timeout/3, awaits_response/1, in_transit/1, cancel_msg/1, not_expired/2]).
-export([idle/3, got_non/3, sent_non/3, got_rst/3, await_aack/3, pack_sent/3, await_pack/3, aack_sent/3, cancelled/3]).
-export([set_timer/2, timeout_after/3, cancel_timer/1, get_receiver/1, check_next_state/1]).

-record(exchange, {
    timestamp = undefined :: integer(),
    expire_time = undefined :: undefined | non_neg_integer(),
    stage = undefined :: atom(),
    trid = undefined :: ecoap_endpoint:trid(),
    receiver = undefined :: undefined | ecoap_endpoint:receiver(),
    msgbin = <<>> :: binary(),
    timer = undefined :: undefined | reference(),
    retry_time = undefined :: undefined | non_neg_integer(),
    retry_count = undefined :: undefined | non_neg_integer()
    }).

-define(ACK_TIMEOUT(ProtoConfig), map_get(ack_timeout, ProtoConfig)).
-define(ACK_RANDOM_FACTOR(ProtoConfig), map_get(ack_random_factor, ProtoConfig)).
-define(MAX_RETRANSMIT(ProtoConfig), map_get(max_retransmit, ProtoConfig)).
-define(PROCESSING_DELAY(ProtoConfig), map_get(processing_delay, ProtoConfig)). 
-define(EXCHANGE_LIFETIME(ProtoConfig), map_get(exchange_lifetime, ProtoConfig)).
-define(NON_LIFETIME(ProtoConfig), map_get(non_lifetime, ProtoConfig)).

-type exchange() :: #exchange{}.

-export_type([exchange/0]).

-include("coap_message.hrl").

not_expired(CurrentTime, #exchange{timestamp=Timestamp, expire_time=ExpireTime}) ->
    CurrentTime - Timestamp < ExpireTime.

init(TrId, Receiver) ->
    #exchange{timestamp=erlang:monotonic_time(), stage=idle, trid=TrId, receiver=Receiver}.

% process incoming message
received(BinMessage, ProtoConfig, Exchange=#exchange{stage=Stage}) ->
    ?MODULE:Stage({in, BinMessage}, ProtoConfig, Exchange).

% process outgoing message
send(Message, ProtoConfig, Exchange=#exchange{stage=Stage}) ->
    ?MODULE:Stage({out, Message}, ProtoConfig, Exchange).

% process timeout
timeout(Event, ProtoConfig, Exchange=#exchange{stage=Stage}) ->
    ?MODULE:Stage({timeout, Event}, ProtoConfig, Exchange).

% cancel msg
cancel_msg(Exchange) ->
    Exchange#exchange{stage=cancelled, msgbin = <<>>}.

set_timer(Timer, Exchange) ->
    Exchange#exchange{timer=Timer}.

get_receiver(#exchange{receiver=Receiver}) -> 
    Receiver.

% check if we can send a response
awaits_response(#exchange{stage=await_aack}) ->
    true;
awaits_response(_Exchange) ->
    false.

% A CON is in transit as long as it has not been acknowledged, rejected, or timed out.
in_transit(#exchange{stage=await_pack}) -> 
    true;
in_transit(_Exchange) -> 
    false.

% ->NON
idle(Msg={in, <<1:2, 1:2, _:12, _Tail/bytes>>}, ProtoConfig, Exchange) ->
    in_non(Msg, ProtoConfig, Exchange#exchange{expire_time=?NON_LIFETIME(ProtoConfig)});
% ->CON
idle(Msg={in, <<1:2, 0:2, _:12, _Tail/bytes>>}, ProtoConfig, Exchange) ->
    in_con(Msg, ProtoConfig, Exchange#exchange{expire_time=?EXCHANGE_LIFETIME(ProtoConfig)});
% NON-> 
idle(Msg={out, #coap_message{type='NON'}}, ProtoConfig, Exchange) ->
    out_non(Msg, ProtoConfig, Exchange#exchange{expire_time=?NON_LIFETIME(ProtoConfig)});
% CON->
idle(Msg={out, #coap_message{type='CON'}}, ProtoConfig, Exchange) ->
    out_con(Msg, ProtoConfig, Exchange#exchange{expire_time=?EXCHANGE_LIFETIME(ProtoConfig)}).

% --- incoming NON
in_non({in, BinMessage}, _, Exchange) ->
    try coap_message:decode(BinMessage) of
        #coap_message{code=Method}=Message when is_atom(Method) ->
            logger:log(debug, "~p received NON request ~p~n", [self(), Message]),
            {[{handle_request, Message}], Exchange#exchange{stage=got_non}};
        #coap_message{}=Message ->
            logger:log(debug, "~p received NON response ~p~n", [self(), Message]),
            {[{handle_respone, Message}], Exchange#exchange{stage=got_non}}
    catch _C:_R ->
            % shall we send reset?
            logger:log(debug, "~p received corrupted msg ~p in stage ~p~n", [self(), BinMessage, ?FUNCTION_NAME]),
            {[], Exchange#exchange{stage=got_non}}
    end.

got_non({in, BinMessage}, _, Exchange) ->
    % ignore retransmission
    logger:log(debug, "~p received repeated NON msg MID=~p~n", [self(), coap_message:get_id(BinMessage)]),
    {[], Exchange#exchange{stage=got_non}}.

% --- outgoing NON
out_non({out, Message}, _, Exchange) ->
    logger:log(debug, "~p send outgoing NON msg ~p~n", [self(), Message]),
    BinMessage = coap_message:encode(Message),
    {[{send, BinMessage}], Exchange#exchange{stage=sent_non}}.

% we may get reset
sent_non({in, BinMessage}, _, Exchange) ->
    try coap_message:decode(BinMessage) of
        #coap_message{type='RST'}=Message ->
            logger:log(debug, "~p received RST msg ~p~n", [self(), Message]),
            {[{handle_error, Message, 'RST'}], Exchange#exchange{stage=got_rst}};
        #coap_message{}=Message->
            logger:log(debug, "~p received irrelevant msg ~p~n", [self(), Message]),
            {[], Exchange#exchange{stage=sent_non}}
    catch _C:_R ->
            logger:log(debug, "~p received corrupted msg ~p in stage ~p~n", [self(), BinMessage, ?FUNCTION_NAME]),
            {[], Exchange#exchange{stage=sent_non}}
    end.
            
got_rst({in, BinMessage}, _, Exchange)->
    logger:log(debug, "~p received repeated RST msg MID=~p~n", [self(), coap_message:get_id(BinMessage)]),
    {[], Exchange#exchange{stage=got_rst}}.

% --- incoming CON->ACK|RST
in_con({in, BinMessage}, ProtoConfig, Exchange) ->
    try coap_message:decode(BinMessage) of
        #coap_message{code=undefined}=Message ->
            % provoked reset
            logger:log(debug, "~p received ping msg ~p~n", [self(), Message]),
            go_pack_sent(ecoap_request:rst(Message), Exchange);
        #coap_message{code=Method}=Message when is_atom(Method) ->
            logger:log(debug, "~p received CON request ~p~n", [self(), Message]),
            {Actions, NewExchange} = go_await_aack(Message, ProtoConfig, Exchange),
            {[{handle_request, Message} | Actions], NewExchange};
        #coap_message{}=Message ->
            logger:log(debug, "~p received CON response ~p~n", [self(), Message]),
            {Actions, NewExchange} = go_await_aack(Message, ProtoConfig, Exchange),
            {[{handle_response, Message} | Actions], NewExchange}
    catch 
        _C:_R ->
            logger:log(debug, "~p received corrupted msg ~p in stage ~p~n", [self(), BinMessage, ?FUNCTION_NAME]),
            go_pack_sent(ecoap_request:rst(coap_message:get_id(BinMessage)), Exchange)
    end.

go_await_aack(Message, ProtoConfig, Exchange) ->
    % we may need to ack the message
    BinAck = coap_message:encode(ecoap_request:ack(Message)),
    {[{start_timer, ?PROCESSING_DELAY(ProtoConfig)}], Exchange#exchange{stage=await_aack, msgbin=BinAck}}.

await_aack({in, BinMessage}, _, Exchange) ->
    % ignore retransmission
    logger:log(debug, "~p received repeated CON msg MID=~p~n", [self(), coap_message:get_id(BinMessage)]),
    {[], Exchange#exchange{stage=await_aack}};

await_aack({timeout, await_aack}, _, Exchange=#exchange{msgbin=BinAck}) ->
    logger:log(debug, "~p <- ack [application didn't respond]~n", [self()]),
    {[{send, BinAck}], Exchange#exchange{stage=pack_sent}};

await_aack({out, Ack}, _, Exchange) ->
    % set correct type for a piggybacked response
    Ack2 = case Ack of
        #coap_message{type='CON'} -> Ack#coap_message{type='ACK'};
        _ -> Ack
    end,
    {Actions, NewExchange} = go_pack_sent(Ack2, Exchange),
    {[cancel_timer | Actions], NewExchange}.

go_pack_sent(Ack, Exchange) ->
    logger:log(debug, "~p send ACK/RST msg ~p~n", [self(), Ack]),
    BinAck = coap_message:encode(Ack),
    {[{send, BinAck}], Exchange#exchange{stage=pack_sent, msgbin=BinAck}}.

pack_sent({in, BinMessage}, _, Exchange=#exchange{msgbin=BinAck}) ->
    % retransmit the ack
    logger:log(debug, "~p re-send ACK/RST msg MID=~p~n", [self(), coap_message:get_id(BinMessage)]),
    {[{send, BinAck}], Exchange#exchange{stage=pack_sent}};
pack_sent({timeout, await_aack}, _, Exchange) ->
	% in case the timeout msg was sent before we cancel the timer
	% ignore the msg
    {[], Exchange#exchange{stage=pack_sent}}.

% Note that, as the underlying datagram
% transport may not be sequence-preserving, the Confirmable message
% carrying the response may actually arrive before or after the
% Acknowledgement message for the request; for the purposes of
% terminating the retransmission sequence, this also serves as an
% acknowledgement.

% If the request message is Non-confirmable, then the response SHOULD
% be returned in a Non-confirmable message as well.  However, an
% endpoint MUST be prepared to receive a Non-confirmable response
% (preceded or followed by an Empty Acknowledgement message) in reply
% to a Confirmable request, or a Confirmable response in reply to a
% Non-confirmable request.

%% TODO: CON->CON does not cancel retransmission of the request

% --- outgoing CON->ACK|RST
out_con({out, Message}, ProtoConfig, Exchange) ->
    %io:fwrite("~p send outgoing con msg ~p~n", [self(), Message]),
    logger:log(debug, "~p send outgoing CON msg ~p~n", [self(), Message]),
    BinMessage = coap_message:encode(Message),
    % _ = rand:seed(exs1024),
    TimeOut = ?ACK_TIMEOUT(ProtoConfig)+rand:uniform(?ACK_RANDOM_FACTOR(ProtoConfig)),
    {[{send, BinMessage}, {start_timer, TimeOut}], Exchange#exchange{msgbin=BinMessage, retry_count=0, retry_time=TimeOut, stage=await_pack}}.

% peer ack
await_pack({in, BinAck}, _, Exchange) ->
    try coap_message:decode(BinAck) of
        #coap_message{type='ACK', code=undefined}=Message ->
            % this is an empty ack for separate response or observe notification
            % handle_ack(Message, ProtoConfig, Exchange),
            % since we can confirm when an outgoing confirmable message
            % has been acknowledged or reset, we can safely clean the msgbin 
            % which won't be used again from this moment
            logger:log(debug, "~p received empty ACK msg ~p~n", [self(), Message]),
            {[cancel_timer, {handle_ack, Message}], Exchange#exchange{msgbin= <<>>, stage=aack_sent}};
        #coap_message{type='RST', code=undefined}=Message ->
            logger:log(debug, "~p received RST msg ~p~n", [self(), Message]),
            {[cancel_timer, {handle_error, Message, 'RST'}], Exchange#exchange{msgbin= <<>>, stage=aack_sent}};
        #coap_message{type='ACK'}=Message ->
            logger:log(debug, "~p received ACK response ~p~n", [self(), Message]),
            {[cancel_timer, {handle_response, Message}], Exchange#exchange{msgbin= <<>>, stage=aack_sent}}
    catch _C:_R ->
            % shall we inform the receiver the error?
            logger:log(debug, "~p received corrupted msg ~p in stage ~p~n", [self(), BinAck, ?FUNCTION_NAME]),
            {[], Exchange#exchange{stage=await_pack}}
    end;

await_pack({timeout, await_pack}, ProtoConfig, Exchange=#exchange{msgbin=BinMessage, retry_time=TimeOut, retry_count=Count}) when Count < ?MAX_RETRANSMIT(ProtoConfig) ->
    % BinMessage = coap_message:encode(Message),
    logger:log(debug, "~p resend CON msg for ~p time after ~pms have passed~n", [self(), Count, TimeOut]),
    TimeOut2 = TimeOut*2,
    {[{send, BinMessage}, {start_timer, TimeOut2}], Exchange#exchange{retry_time=TimeOut2, retry_count=Count+1, stage=await_pack}};

await_pack({timeout, await_pack}, _, Exchange=#exchange{trid={out, MsgId}}) ->
    logger:log(debug, "~p timeout for outgoing CON msg~n", [self()]),
    {[{handle_error, ecoap_request:rst(MsgId), timeout}], Exchange#exchange{msgbin= <<>>, stage=aack_sent}}.

aack_sent({in, _Ack}, _, Exchange) ->
    % ignore ack retransmission
    logger:log(debug, "~p received repeated ACK/RST msg~n", [self()]),
    {[], Exchange#exchange{stage=aack_sent}};
aack_sent({timeout, await_pack}, _TransArgs, Exchange) ->
	% in case the timeout msg was sent before we cancel the timer
	% ignore the msg
    {[], Exchange#exchange{stage=aack_sent}}.

cancelled({_, _}, _, Exchange) ->
    {[], Exchange}.

check_next_state(#exchange{expire_time=0, stage=Stage}) when Stage =/= await_aack, Stage =/= await_pack -> undefined;
check_next_state(Exchange) -> Exchange.

timeout_after(Time, EndpointPid, #exchange{trid=TrId, stage=Stage}) ->
    erlang:send_after(Time, EndpointPid, {timeout, TrId, Stage}).

cancel_timer(#exchange{timer=Timer}) ->
    erlang:cancel_timer(Timer, [{async, true}, {info, false}]).