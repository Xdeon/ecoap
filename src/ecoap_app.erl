-module(ecoap_app).
-behaviour(application).

-export([start/2]).
-export([stop/1]).

-include("ecoap.hrl").

start(_Type, _Args) ->
	InPort = application:get_env(ecoap, port, ?DEFAULT_COAP_PORT),
	Opts = application:get_env(ecoap, socket_opts, []),
	ecoap_sup:start_link(InPort, Opts).

stop(_State) ->
	ok.
