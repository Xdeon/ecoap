PROJECT = simple_server
PROJECT_DESCRIPTION = A demo CoAP server
PROJECT_VERSION = 0.0.1

LOCAL_DEPS = mnesia
DEPS = ecoap
dep_ecoap = git https://github.com/Xdeon/ecoap dev

define PROJECT_ENV
[{port, 5683}]
endef

include ../../erlang.mk
