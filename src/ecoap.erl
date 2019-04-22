-module(ecoap).
-export([start_udp/2, stop_udp/1, start_dtls/2, stop_dtls/1]).

-include("ecoap.hrl").

-type config() :: #{
	routes => [ecoap_registry:route_rule()],
	protocol_config => map(),
	handshake_timeout => timeout(),
	transport_opts => [gen_udp:option()] | [ssl:connect_option()],
	num_acceptors => integer()
}.

-export_type([config/0]).

-spec start_udp(atom(), config()) -> supervisor:startchild_ret().
start_udp(Name, Config) ->
	TransOpts0 = maps:get(transport_opts, Config, []),
	TransOpts = [{port, ?DEFAULT_COAP_PORT}|TransOpts0],
	Routes = maps:get(routes, Config, []),
	ProtoConfig = maps:get(protocol_config, Config, #{}),
	ok = ecoap_registry:register_handler(Routes),
	ecoap_sup:start_server({ecoap_udp_socket, start_link, [Name, TransOpts, ProtoConfig]}, Name, worker).

-spec start_dtls(atom(), config()) -> supervisor:startchild_ret().
start_dtls(Name, Config) ->
	Routes = maps:get(routes, Config, []),
	ok = ecoap_registry:register_handler(Routes),
	ecoap_sup:start_server({ecoap_dtls_listener_sup, start_link, [Name, Config]}, Name, supervisor).

-spec stop_udp(atom()) -> ok | {error, term()}.
stop_udp(Name) ->
    ecoap_sup:stop_server(Name).

-spec stop_dtls(atom()) -> ok | {error, term()}.
stop_dtls(Name) ->
	ecoap_sup:stop_server(Name).