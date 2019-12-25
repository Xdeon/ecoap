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
	start_listener(Name, udp, TransOpts, worker, Config, []).

-spec start_dtls(atom(), [ssl:connect_option()], config()) -> supervisor:startchild_ret().
start_dtls(Name, TransOpts, Config) ->
	case lists:keymember(cert, 1, TransOpts)
			orelse lists:keymember(certfile, 1, TransOpts)
			orelse lists:keymember(sni_fun, 1, TransOpts)
			orelse lists:keymember(sni_hosts, 1, TransOpts) 
			orelse lists:keymember(psk_identity, 1, TransOpts) of
		true ->
			TimeOut = maps:get(handshake_timeout, Config, 5000),
			NumAcceptors = maps:get(num_acceptors, Config, 10),
			start_listener(Name, dtls, TransOpts, supervisor, Config, [TimeOut, NumAcceptors]);
		false ->
			{error, no_cert_or_psk}
	end.

-spec stop_udp(atom()) -> ok | {error, term()}.
stop_udp(Name) ->
    stop_listener(Name).

-spec stop_dtls(atom()) -> ok | {error, term()}.
stop_dtls(Name) ->
	% temporary fix to: when listen socket holder process crashes the socket is not closed properly
	case stop_listener(Name) of
		ok -> 
			(ecoap_socket:listener_module(dtls)):close(Name);
		Error ->
			Error
	end.
	% end of fix

start_listener(Name, Transport, TransOpts, Type, Config, Args) ->
	{Routes, ProtoConfig} = init_common_config(Config),
	ok = ecoap_registry:register_handler(Routes),
	ok = ecoap_registry:set_new_listener_config(Name, TransOpts, ProtoConfig),
	maybe_started(ecoap_sup:start_server({ecoap_socket:listener_module(Transport), start_link, 
		[Name, TransOpts, ProtoConfig|Args]}, Name, Type)).

stop_listener(Name) ->
	ecoap_sup:stop_server(Name).

init_common_config(Config) ->
	Routes = maps:get(routes, Config, []),
	ProtoConfig = maps:get(protocol_config, Config, #{}),
	{Routes, ProtoConfig}.

maybe_started({error, {{shutdown, {failed_to_start_child, _, {listen_error, _, Reason}}}, _}}=Error) ->
	start_error(Reason, Error);
maybe_started(Res) ->
	Res.

start_error(E=eaddrinuse, _) -> {error, E};
start_error(E=eacces, _) -> {error, E};
start_error(E=no_cert, _) -> {error, E};
start_error(_, Error) -> Error.	

