-module(ecoap_socket).

-callback send(Socket, EpID, Bin) -> ok | {error, term()} when
	Socket :: gen_udp:socket() | ssl:sslsocket() | term(),
	EpID :: ecoap_endpoint:ecoap_endpoint_id(),
	Bin :: binary().

-callback get_endpoint(Pid, EpID) -> {ok, EpPid} | {error, term()} when
	Pid :: pid(),
	EpID :: ecoap_endpoint:ecoap_endpoint_id(),
	EpPid :: pid().