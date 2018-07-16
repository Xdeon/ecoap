-module(ecoap).
-export([start_udp/3, stop_udp/1]).

-include("ecoap.hrl").

start_udp(Name, SocketOpts, Env) ->
	Routes = maps:get(routes, Env, []),
	Config = maps:remove(routes, Env),
	ok = ecoap_registry:register_handler(Routes),
	ecoap_sup:start_server({ecoap_udp_socket, start_link, []}, Name, [{port, ?DEFAULT_COAP_PORT}|SocketOpts], Config).

stop_udp(Name) ->
    ecoap_sup:stop_server(Name).