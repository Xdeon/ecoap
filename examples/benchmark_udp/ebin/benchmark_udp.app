{application, 'benchmark_udp', [
	{description, "ecoap benchmark server on UDP"},
	{vsn, "0.0.1"},
	{modules, ['benchmark','benchmark_udp_app','benchmark_udp_sup']},
	{registered, [benchmark_udp_sup]},
	{applications, [kernel,stdlib,ecoap]},
	{mod, {benchmark_udp_app, []}},
	{env, []}
]}.