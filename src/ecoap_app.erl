-module(ecoap_app).
-behaviour(application).

-export([start/2]).
-export([stop/1]).

-define(DEFAULT_COAP_PORT, 5683).

start(_Type, _Args) ->
	ecoap_sup:start_link(?DEFAULT_COAP_PORT).

stop(_State) ->
	ok.
