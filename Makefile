PROJECT = ecoap
PROJECT_DESCRIPTION = An Erlang CoAP client/server
PROJECT_VERSION = 0.0.1
PROJECT_REGISTERED = ecoap_socket ecoap_registry
PROJECT_ENV = [{port, 5683}]

LOCAL_DEPS = crypto

EUNIT_OPTS = verbose

include erlang.mk

app:: rebar.config
