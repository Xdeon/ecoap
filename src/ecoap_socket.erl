-module(ecoap_socket).
-export([port/1, transport_module/1, socket_opts/2]).

-define(READ_PACKETS, 1000).

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

port(udp) -> 5683;
port(dtls) -> 5684.

transport_module(udp) -> ecoap_udp_socket;
transport_module(dtls) -> ecoap_dtls_socket.

socket_opts(Transport, Options) ->
	merge_sock_opts(default_socket_opts(Transport), Options).

default_socket_opts(udp) -> [binary, {active, false}, {reuseaddr, true}, {read_packets, ?READ_PACKETS}];
default_socket_opts(dtls) -> [binary, {active, false}, {reuseaddr, true}, {protocol, dtls}, {read_packets, ?READ_PACKETS}].

merge_sock_opts(Defaults, Options) ->
    lists:foldl(
        fun({Opt, Val}, Acc) ->
                lists:keystore(Opt, 1, Acc, {Opt, Val});
            (Opt, Acc) ->
                case lists:member(Opt, Acc) of
                    true  -> Acc;
                    false -> [Opt | Acc]
                end
    end, Defaults, Options).