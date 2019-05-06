PROJECT = ecoap
PROJECT_DESCRIPTION = An Erlang CoAP client/server
PROJECT_VERSION = 0.1.0
PROJECT_REGISTERED = ecoap_udp_socket ecoap_registry

# DEPS = cowlib
LOCAL_DEPS = crypto ssl

# EUNIT_OPTS = verbose

# PLT_APPS = ssl

include erlang.mk

ERLC_OPTS += +report +verbose +warn_deprecated_function +warn_deprecated_type +warn_untyped_record +warn_unused_import +inline_list_funcs

SHELL_OPTS = +K true +spp true -kernel start_pg2 true

app:: rebar.config