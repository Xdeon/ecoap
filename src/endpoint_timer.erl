-module(endpoint_timer).
-export([start_simple/3, start_standard/3, start_kick/2, cancel_timer/1, restart_kick/1, kick/1, is_kicked/1]).

% This timer is intended to be used when NODEDUP is set or EXCHANGE_LIFETIME is strongly reduced.
% Under such situations, it is desired that an ecoap_endpoint process could determine
% termination based on past incoming messages. That is, keep alive if any messages have been received
% during the last timer cycle and otherwise terminate.
% Notice an ecoap_endpoint will last for one more timer cycle if an EXCHANGE_LIFETIME shorter than timer cycle is being used.
% This timer will not change server functionality with normal EXCHNAGE_LIFETIME setting.

-record(timer_state, {
	interval = undefined :: timeout(),
	kicked = undefined :: boolean(),
	timer = undefined :: timer(),
	msg = undefined :: term()
}).

-type timer() :: reference().
-type timer_state() :: #timer_state{}.
-export_type([timer_state/0]).

-spec start_simple(timeout(), pid(), term()) -> timer().
start_simple(Time, Pid, Msg) ->
	erlang:send_after(Time, Pid, Msg).

-spec start_standard(timeout(), pid(), term()) -> timer().
start_standard(Time, Pid, Msg) ->
	erlang:start_timer(Time, Pid, Msg).

-spec start_kick(timeout(), term()) -> timer_state().
start_kick(Time, Msg) ->
	Timer = erlang:send_after(Time, self(), Msg),
	#timer_state{interval=Time, kicked=false, timer=Timer, msg=Msg}.

-spec cancel_timer(timer_state() | timer()) -> ok.
cancel_timer(Timer) when is_reference(Timer) ->
	erlang:cancel_timer(Timer, [{async, true}, {info, false}]);
cancel_timer(#timer_state{timer=Timer}) ->
	cancel_timer(Timer).

-spec restart_kick(timer_state()) -> timer_state().
restart_kick(State=#timer_state{interval=Time, msg=Msg}) ->
	Timer = erlang:send_after(Time, self(), Msg),
	State#timer_state{kicked=false, timer=Timer}.

-spec kick(timer_state()) -> timer_state().
kick(State=#timer_state{kicked=true}) ->
	State;
kick(State=#timer_state{kicked=false}) ->
	State#timer_state{kicked=true}.

-spec is_kicked(timer_state()) -> boolean().
is_kicked(#timer_state{kicked=Kicked}) ->
	Kicked.

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

timer_test_() ->
	Msg = timeout,
	Timer = start_kick(10, Msg),
	Timer2 = kick(Timer),
	[
		?_assertEqual(false, is_kicked(Timer)),
		?_assertEqual(Msg, receive Any -> Any end),
		?_assertEqual(true, is_kicked(Timer2))
	].

-endif.
