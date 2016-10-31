PROJECT = ecoap
PROJECT_DESCRIPTION = An Erlang CoAP client/server
PROJECT_VERSION = 0.0.1
PROJECT_REGISTERED = ecoap_socket ecoap_registry
PROJECT_ENV = [{port, 5683}, {deduplication, true}]

LOCAL_DEPS = crypto

include erlang.mk
