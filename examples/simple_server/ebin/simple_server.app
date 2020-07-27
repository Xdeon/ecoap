{application, 'simple_server', [
	{description, "A demo CoAP server"},
	{vsn, "0.0.1"},
	{modules, ['simple','simple_server_app','simple_server_sup']},
	{registered, [simple_server_sup]},
	{applications, [kernel,stdlib,mnesia,ecoap]},
	{mod, {simple_server_app, []}},
	{env, [{port, 5683}]}
]}.