-module(ecoap_app).
-behaviour(application).

-export([start/2]).
-export([stop/1]).

-include("ecoap.hrl").

start(_Type, _Args) ->
	InPort = case application:get_env(port) of
				undefined -> ?DEFAULT_COAP_PORT;
				{ok, Port} -> Port
			 end,
	{ok, Opts} = application:get_env(socket_opts),
	ecoap_sup:start_link(InPort, Opts).

stop(_State) ->
	ok.
