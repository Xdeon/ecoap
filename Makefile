PROJECT = ecoap
PROJECT_DESCRIPTION = An Erlang CoAP client/server
PROJECT_VERSION = 0.0.1
PROJECT_REGISTERED = ecoap_socket ecoap_registry
PROJECT_ENV = [{port, 5683}, \
			   {socket_opts, [{recbuf, 10485760}, {sndbuf, 10485760}, {buffer, 10485760}, {high_msgq_watermark, 16384}, {low_msgq_watermark, 8192}]}]

LOCAL_DEPS = crypto

DEPS += ecoap_common
dep_ecoap_common = git https://Xdeon@bitbucket.org/Xdeon/ecoap_common.git master

EUNIT_OPTS = verbose

# ERLC_OPTS = -Dnodedup

include erlang.mk

app:: rebar.config
