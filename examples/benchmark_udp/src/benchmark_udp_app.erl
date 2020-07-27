-module(benchmark_udp_app).
-behaviour(application).

-export([start/0, start/2]).
-export([stop/0, stop/1]).

start() ->
    {ok, _Started} = application:ensure_all_started(benchmark_udp).

stop() ->
	application:stop(benchmark_udp).

start(_Type, _Args) ->
	{ok, _} = ecoap:start_udp(benchmark_udp, 
        [
            {ip, {0,0,0,0}}, 
            {port, 5683}, 
            {recbuf, 1048576}, 
            {sndbuf, 1048576}
        ],
        #{routes => routes(), protocol_config => #{exchange_lifetime => 1500}}),
	benchmark_udp_sup:start_link().

stop(_State) ->
	ok = ecoap:stop_udp(benchmark_udp).

routes() ->
    [
            {[<<"benchmark">>], benchmark},
            {[<<"fibonacci">>], benchmark},
            {[<<"helloWorld">>], benchmark},
            {[<<"shutdown">>], benchmark}
    ].