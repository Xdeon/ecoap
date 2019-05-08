-module(ecoap).
-export([start_udp/2, stop_udp/1, start_dtls/2, stop_dtls/1]).

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
	{Routes, TransOpts, ProtoConfig} = init_common_config(Config, udp),
	ok = ecoap_registry:register_handler(Routes),
	ok = ecoap_registry:set_new_listener_config(Name, TransOpts, ProtoConfig),
	ecoap_sup:start_server({ecoap_udp_socket, start_link, [Name, TransOpts, ProtoConfig]}, Name, worker).

-spec start_dtls(atom(), config()) -> supervisor:startchild_ret().
start_dtls(Name, Config) ->
	{Routes, TransOpts, ProtoConfig} = init_common_config(Config, dtls),
	case lists:keymember(cert, 1, TransOpts)
			orelse lists:keymember(certfile, 1, TransOpts)
			orelse lists:keymember(sni_fun, 1, TransOpts)
			orelse lists:keymember(sni_hosts, 1, TransOpts) of
		true ->
			TimeOut = maps:get(handshake_timeout, Config, 5000),
			NumAcceptors = maps:get(num_acceptors, Config, 10),
			ok = ecoap_registry:register_handler(Routes),
			ok = ecoap_registry:set_new_listener_config(Name, TransOpts, ProtoConfig),
			ecoap_sup:start_server({ecoap_dtls_listener_sup, start_link, 
				[Name, TransOpts, ProtoConfig, TimeOut, NumAcceptors]}, Name, supervisor);
		false ->
			{error, no_cert}
	end.

-spec stop_udp(atom()) -> ok | {error, term()}.
stop_udp(Name) ->
    ecoap_sup:stop_server(Name).

-spec stop_dtls(atom()) -> ok | {error, term()}.
stop_dtls(Name) ->
	ecoap_sup:stop_server(Name).

init_common_config(Config, Transport) ->
	Routes = maps:get(routes, Config, []),
	% add default port which could be surpassed by user-deined port
	TransOpts = [{port, ecoap_socket:default_port(Transport)} | maps:get(transport_opts, Config, [])],
	ProtoConfig = maps:get(protocol_config, Config, #{}),
	{Routes, TransOpts, ProtoConfig}.
