-module(ecoap_app).
-behaviour(application).

-export([start/2]).
-export([stop/1]).

% -define(DEFAULT_COAP_PORT, 5683).

start(_Type, _Args) ->
	{ok, InPort} = application:get_env(port),
	{ok, Opts} = application:get_env(socket_opts),
	ecoap_sup:start_link(InPort, Opts).

stop(_State) ->
	ok.
