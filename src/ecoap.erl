-module(ecoap).
-export([start_udp/3, stop_udp/1, start_dtls/3, stop_dtls/1]).

-type config() :: #{
	routes => [ecoap_registry:route_rule()],
	protocol_config => map(),
	handshake_timeout => timeout(),
	num_acceptors => integer()
}.

-export_type([config/0]).

-spec start_udp(atom(), [gen_udp:option()], config()) -> supervisor:startchild_ret().
start_udp(Name, TransOpts, Config) ->
	{Routes, ProtoConfig} = init_common_config(Config),
	ok = ecoap_registry:register_handler(Routes),
	ok = ecoap_registry:set_new_listener_config(Name, TransOpts, ProtoConfig),
	ecoap_sup:start_server({ecoap_udp_socket, start_link, [Name, TransOpts, ProtoConfig]}, Name, worker).

-spec start_dtls(atom(), [ssl:connect_option()], config()) -> supervisor:startchild_ret().
start_dtls(Name, TransOpts, Config) ->
	{Routes, ProtoConfig} = init_common_config(Config),
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

init_common_config(Config) ->
	Routes = maps:get(routes, Config, []),
	ProtoConfig = maps:get(protocol_config, Config, #{}),
	{Routes, ProtoConfig}.
