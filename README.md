# An Erlang CoAP Server/Client

ecoap is a variation of [gen_coap](https://github.com/gotthardp/gen_coap.git) with lots of modifications.

ecoap aims to be a general purpose CoAP framework, but is under heavy development and experiment. Therefore it is **only for personal and experimental use** currently. For the same reason, it may not strictly comply with all license requirements (if any) for a while.

## Usage
### general configurations
```erlang
%% for client
-type client_opts() :: #{
	owner => pid(),
	protocol_config => map(),
	connect_timeout => timeout(),
	protocol => coap | coaps,
	transport => udp | dtls,
	transport_opts => [gen_udp:option()] | [ssl:connect_option()],
	external_socket => ecoap_socket:socket_id()
}.

%% in ecoap_socket.erl
-type socket_id() -> {udp | dtls, pid()}.

%% for server
-type config() :: #{
	routes => [ecoap_registry:route_rule()],
	protocol_config => map(),
	handshake_timeout => timeout(),
	num_acceptors => integer()
}.

%% in ecoap_registry.erl
-type route_rule() :: {[binary()], module()}.

%% for protocol
-type protocol_config() :: #{
	token_length := 0..8, 
	exchange_lifetime := non_neg_integer(),
	non_lifetime := non_neg_integer(),
	processing_delay := non_neg_integer(),
	max_retransmit := non_neg_integer(),
	ack_random_factor := non_neg_integer(),
	ack_timeout := non_neg_integer(),
	max_block_size := non_neg_integer(),
	max_body_size := non_neg_integer(),
	endpoint_pid => pid()
}.
```

### client
```erlang
%% in ecoap_client.erl
-spec open(host(), port_number()) -> {ok, pid()} | {error, term()}.
-spec open(host(), port_number(), client_opts()) -> {ok, pid()} | {error, term()}.

-type host() :: inet:hostname() | inet:ip_address() | binary().
-type port_number() :: inet:port_number().
```

Example:

```erlang
{ok, C} = ecoap_client:open("californium.eclipse.org", 5683).
case ecoap_client:discover(C) of
	{ok, Code, Content} -> ...
	{error, Error} -> ...
end.
```

### server
```erlang
%% in ecoap.erl
-spec start_udp(atom(), [gen_udp:option()], config()) -> supervisor:startchild_ret().
-spec start_dtls(atom(), [ssl:connect_option()], config()) -> supervisor:startchild_ret().
```

Example:

```erlang
%% Assume current module implemets ecoap_handler behaviour
Routes = [
        {[<<"benchmark">>], ?MODULE},
        {[<<"fibonacci">>], ?MODULE},
        {[<<"helloWorld">>], ?MODULE},
        {[<<"shutdown">>], ?MODULE}
],
{ok, _} = ecoap:start_udp(benchmark_udp, [
		{port, 5683}, 
		{recbuf, 1048576},
		{sndbuf, 1048576}
		], #{routes => Routes, protocol_config => #{exchange_lifetime => 1500}}),
{ok, _} = ecoap:start_dtls(benchmark_dtls, [
        {port, 5684}, 
        {keyfile, ...}, 
        {certfile, ...}, 
        {cacertfile, ...}, 
		...
    ], #{routes => Routes}).
```

See /src/example for more details.
