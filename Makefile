PROJECT = ecoap
PROJECT_DESCRIPTION = An Erlang CoAP client/server
PROJECT_VERSION = 0.1.0
PROJECT_REGISTERED = ecoap_udp_socket ecoap_dtls_listener_sup ecoap_registry

DEPS = spg cowlib
dep_spg = git https://github.com/max-au/spg.git
dep_cowlib = git https://github.com/ninenines/cowlib.git
LOCAL_DEPS = crypto ssl

# EUNIT_OPTS = verbose

# PLT_APPS = ssl

include erlang.mk

ERLC_OPTS += +report +verbose +warn_deprecated_function +warn_deprecated_type +warn_untyped_record +warn_unused_import +inline_list_funcs

SHELL_OPTS = +spp true -kernel start_pg true

app:: rebar.config
