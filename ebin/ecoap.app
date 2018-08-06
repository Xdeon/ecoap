{application, 'ecoap', [
	{description, "An Erlang CoAP client/server"},
	{vsn, "0.0.1"},
	{modules, ['benchmark','coap_content','coap_iana','coap_message','core_link','core_link_parser','core_link_scanner','ecoap','ecoap_app','ecoap_client','ecoap_config','ecoap_endpoint','ecoap_exchange','ecoap_handler','ecoap_handler_sup','ecoap_message_id','ecoap_message_token','ecoap_registry','ecoap_request','ecoap_server_sup','ecoap_simple_client','ecoap_socket','ecoap_sup','ecoap_udp_socket','ecoap_uri','endpoint_sup','endpoint_sup_sup','endpoint_timer','resource_directory','test_resource']},
	{registered, [ecoap_sup,ecoap_udp_socket,ecoap_registry]},
	{applications, [kernel,stdlib,crypto,inets]},
	{mod, {ecoap_app, []}},
	{env, []}
]}.