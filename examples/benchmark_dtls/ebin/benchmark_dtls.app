{application, 'benchmark_dtls', [
	{description, "ecoap benchmark server on DTLS"},
	{vsn, "0.0.1"},
	{modules, ['benchmark','benchmark_dtls_app','benchmark_dtls_sup']},
	{registered, [benchmark_dtls_sup]},
	{applications, [kernel,stdlib,ecoap]},
	{mod, {benchmark_dtls_app, []}},
	{env, [{security, cert}]}
]}.