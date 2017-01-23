PROJECT = ecoap
PROJECT_DESCRIPTION = An Erlang CoAP client/server
PROJECT_VERSION = 0.0.1
PROJECT_REGISTERED = ecoap_socket ecoap_registry
PROJECT_ENV = [{port, 5683}, \
			   {socket_opts, [{recbuf, 10485760}, {sndbuf, 10485760}, {buffer, 10485760}, {high_msgq_watermark, 1048576}]}]

LOCAL_DEPS = crypto

EUNIT_OPTS = verbose

include erlang.mk

app:: rebar.config
