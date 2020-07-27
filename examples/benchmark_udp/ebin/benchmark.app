{application, 'benchmark', [
	{description, "ecoap benchmark server"},
	{vsn, "0.0.1"},
	{modules, ['benchmark','benchmark_app','benchmark_sup']},
	{registered, [benchmark_sup]},
	{applications, [kernel,stdlib,ecoap]},
	{mod, {benchmark_app, []}},
	{env, []}
]}.