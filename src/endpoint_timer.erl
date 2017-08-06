-module(endpoint_timer).
-export([start_timer/2, cancel_timer/1, restart_timer/1, kick_timer/1, is_kicked/1]).

% This timer is intended to be used when NODEDUP is set or EXCHANGE_LIFETIME is strongly reduced.
% Under such situations, it is desired that an ecoap_endpoint process could determine
% termination based on past incoming messages. That is, keep alive if any messages have been received
% during the last timer cycle and otherwise terminate.
% Notice an ecoap_endpoint will last for one more timer cycle if an EXCHANGE_LIFETIME shorter than timer cycle is being used.
% This timer will not change server functionality with normal EXCHNAGE_LIFETIME setting.

-record(timer_state, {
	interval = undefined :: non_neg_integer(),
	kicked = undefined :: boolean(),
	timer = undefined :: reference(),
	msg = undefined :: any()
}).

-type timer_state() :: #timer_state{}.
-export_type([timer_state/0]).

-spec start_timer(non_neg_integer(), any()) -> timer_state().
start_timer(Time, Msg) ->
	Timer = erlang:send_after(Time, self(), Msg),
	#timer_state{interval=Time, kicked=false, timer=Timer, msg=Msg}.

-spec cancel_timer(timer_state()) -> ok.
cancel_timer(#timer_state{timer=Timer}) ->
	_ = erlang:cancel_timer(Timer),
	ok.

-spec restart_timer(timer_state()) -> timer_state().
restart_timer(State=#timer_state{interval=Time, msg=Msg}) ->
	Timer = erlang:send_after(Time, self(), Msg),
	State#timer_state{kicked=false, timer=Timer}.

-spec kick_timer(timer_state()) -> timer_state().
kick_timer(State=#timer_state{kicked=false}) ->
	State#timer_state{kicked=true};
kick_timer(State) ->
	State.

-spec is_kicked(timer_state()) -> boolean().
is_kicked(#timer_state{kicked=Kicked}) ->
	Kicked.

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

timer_test_() ->
	Msg = timeout,
	Timer = start_timer(10, Msg),
	Timer2 = kick_timer(Timer),
	[
		?_assertEqual(false, is_kicked(Timer)),
		?_assertEqual(Msg, receive Any -> Any end),
		?_assertEqual(true, is_kicked(Timer2))
	].

-endif.
