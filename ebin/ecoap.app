{application, 'ecoap', [
	{description, "An Erlang CoAP client/server"},
	{vsn, "0.0.1"},
	{modules, ['benchmark','coap_content','coap_resource','core_link','core_link_parser','core_link_scanner','ecoap_app','ecoap_client','ecoap_endpoint','ecoap_exchange','ecoap_handler','ecoap_handler_sup','ecoap_reg_sup','ecoap_registry','ecoap_request','ecoap_server_sup','ecoap_simple_client','ecoap_sup','ecoap_udp_socket','ecoap_utils','endpoint_sup','endpoint_sup_sup','endpoint_timer','resource_directory','test_resource']},
	{registered, [ecoap_sup,ecoap_udp_socket,ecoap_registry]},
	{applications, [kernel,stdlib,crypto,ecoap_common]},
	{mod, {ecoap_app, []}},
	{env, [{port, 5683}, {socket_opts, [{recbuf, 1048576}, {sndbuf, 1048576}]}]}
]}.