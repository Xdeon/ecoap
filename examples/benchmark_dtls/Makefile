PROJECT = benchmark_dtls
PROJECT_DESCRIPTION = ecoap benchmark server on DTLS
PROJECT_VERSION = 0.0.1

define PROJECT_ENV
[{security, cert}]
endef

DEPS = ecoap
dep_ecoap = git https://github.com/Xdeon/ecoap dev

include ../../erlang.mk
