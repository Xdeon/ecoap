-module(ecoap_socket).

-type socket_id() :: {atom(), pid() | atom() | tuple()}.
-export_type([socket_id/0]).

-callback send(Socket, EpID, Bin) -> ok | {error, term()} when
	Socket :: gen_udp:socket() | ssl:sslsocket() | term(),
	EpID :: ecoap_endpoint:ecoap_endpoint_id(),
	Bin :: binary().

-callback get_endpoint(Pid, EpAddr) -> {ok, EpPid} | {error, term()} when
	Pid :: pid(),
	EpAddr :: ecoap_endpoint:endpoint_addr(),
	EpPid :: pid().