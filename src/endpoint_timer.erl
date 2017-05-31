-module(endpoint_timer).
-export([start_timer/2, cancel_timer/1, restart_timer/1, kick_timer/1, is_timeout/1]).

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
kick_timer(State=#timer_state{kicked=true}) ->
	State.

-spec is_timeout(timer_state()) -> boolean().
is_timeout(#timer_state{kicked=true}) ->
	false;
is_timeout(#timer_state{kicked=false}) ->
	true.
