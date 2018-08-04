-module(ecoap).
-export([start_udp/3, stop_udp/1]).

-include("ecoap.hrl").

% -type env() :: #{
% 	exchange_lifetime => non_neg_integer(),
% 	non_neg_integer => non_neg_integer(),
% 	processing_delay => non_neg_integer(),
% 	max_retransmit => non_neg_integer(),
% 	ack_random_factor => non_neg_integer(),
% 	ack_timeout => non_neg_integer(),
% 	max_block_size => non_neg_integer(),
% 	max_body_size => non_neg_integer(),
% 	token_length => non_neg_integer(),
% 	_ => _
% }.

-type config() :: map().

-export_type([config/0]).

-spec start_udp(atom(), [tuple()], config()) -> {ok, pid()} | {error, {already_started, pid()}} | {error, term()}.
start_udp(Name, SocketOpts, Config0) ->
	Routes = maps:get(routes, Config0, []),
	Config = maps:remove(routes, Config0),
	ok = ecoap_registry:register_handler(Routes),
	ecoap_sup:start_server({ecoap_udp_socket, start_link, []}, Name, [{port, ?DEFAULT_COAP_PORT}|SocketOpts], Config).

-spec stop_udp(atom()) -> ok.
stop_udp(Name) ->
    ecoap_sup:stop_server(Name).