-module(ecoap_app).
-behaviour(application).

-export([start/2]).
-export([stop/1]).

% -define(DEFAULT_COAP_PORT, 5683).

start(_Type, _Args) ->
	{ok, InPort} = application:get_env(port),
	ecoap_sup:start_link(InPort).

stop(_State) ->
	ok.
