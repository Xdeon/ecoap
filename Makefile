PROJECT = ecoap
PROJECT_DESCRIPTION = An Erlang CoAP client/server
PROJECT_VERSION = 0.0.1
PROJECT_REGISTERED = ecoap_socket ecoap_registry
PROJECT_ENV = [{port, 5683}, \
			   {socket_opts, [{recbuf, 1048576}, {sndbuf, 1048576}]}]

LOCAL_DEPS = crypto

DEPS += ecoap_common
dep_ecoap_common = git https://Xdeon@bitbucket.org/Xdeon/ecoap_common.git master

EUNIT_OPTS = verbose

# ERLC_OPTS = -Dnodedup

include erlang.mk

app:: rebar.config
