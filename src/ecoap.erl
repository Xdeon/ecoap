-module(ecoap).
-export([start_udp/3, stop_udp/1]).

-include("ecoap.hrl").

start_udp(Name, SocketOpts, Env) ->
	Routes = maps:get(routes, Env, []),
	Config = maps:remove(routes, Env),
	ok = ecoap_registry:register_handler(Routes),
	ecoap_server_sup:start_socket(udp, Name, [{port, ?DEFAULT_COAP_PORT}|SocketOpts], Config).

stop_udp(Name) ->
    ecoap_server_sup:stop_socket(udp, Name).