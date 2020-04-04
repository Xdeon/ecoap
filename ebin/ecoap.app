{application, 'ecoap', [
	{description, "An Erlang CoAP client/server"},
	{vsn, "0.1.0"},
	{modules, ['benchmark','ecoap','ecoap_app','ecoap_client','ecoap_config','ecoap_content','ecoap_core_link','ecoap_core_link_parser','ecoap_core_link_scanner','ecoap_dtls_listener_sup','ecoap_dtls_socket','ecoap_endpoint','ecoap_endpoint_sup','ecoap_endpoint_sup_sup','ecoap_exchange','ecoap_handler','ecoap_handler_sup','ecoap_iana','ecoap_message','ecoap_message_id','ecoap_message_token','ecoap_registry','ecoap_request','ecoap_resource_directory','ecoap_server_sup','ecoap_simple_client','ecoap_socket','ecoap_sup','ecoap_timer','ecoap_udp_socket','ecoap_uri','test_resource']},
	{registered, [ecoap_sup,ecoap_udp_socket,ecoap_dtls_listener_sup,ecoap_registry]},
	{applications, [kernel,stdlib,crypto,ssl,spg]},
	{mod, {ecoap_app, []}},
	{env, []}
]}.