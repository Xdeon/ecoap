-module(ecoap).
-export([start_udp/2, stop_udp/0]).

-include("ecoap.hrl").

start_udp(SocketOpts, Env) ->
	Routes = maps:get(routes, Env, []),
	ok = ecoap_registry:register_handler(Routes),
	ecoap_server_sup:start_socket(udp, [{port, ?DEFAULT_COAP_PORT}|SocketOpts]).

stop_udp() ->
    ecoap_server_sup:stop_socket(udp).