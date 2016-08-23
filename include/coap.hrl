-type coap_endpoints() :: #{coap_endpoint_id() => {pid(), pid(), reference()}}.

-type coap_endpoint_id() :: {inet:ip_address(), inet:port_number()}.

-type from() :: {pid(), term()}.

-record(coap_message, {
	type = undefined :: coap_type(), 
	code = undefined :: undefined | coap_method() | coap_success() | coap_error(), 
	id = undefined :: 0..65535, 
	token = <<>> :: binary(),
	options = [] :: list(tuple()), 
	payload = <<>> :: binary()
}).


-type coap_message() :: #coap_message{}.

-type coap_type() :: 'CON' | 'NON' | 'ACK' | 'RST' .

-type coap_method() :: 'GET' | 'POST' | 'PUT' | 'DELETE'.

-type coap_success() :: {ok, 'CREATED' | 'DELETED' | 'VALID' | 'CHANGED' | 'CONTENT' | 'CONTINUE'}. 

-type coap_error() :: {error, 'BAD_REQUEST' 
							| 'UAUTHORIZED' 
							| 'BAD_OPTION' 
							| 'FORBIDDEN' 
							| 'NOT_FOUND' 
							| 'METHOD_NOT_ALLOWED' 
							| 'NOT_ACCEPTABLE' 
							| 'REQUEST_ENTITY_INCOMPLETE' 
							| 'PRECONDITION_FAILED' 
							| 'REQUEST_ENTITY_TOO_LARGE' 
							| 'UNSUPPORTED_CONTENT_FORMAT' 
							| 'INTERNAL_SERVER_ERROR' 
							| 'NOT_IMPLEMENTED' 
							| 'BAD_GATEWAY' 
							| 'SERVICE_UNAVAILABLE' 
							| 'GATEWAY_TIMEOUT' 
							| 'PROXYING_NOT_SUPPORTED'}.

-type coap_option() :: 'If-Match'
					| 'Uri-Host'
					| 'ETag'
					| 'If-None-Match'
					| 'Uri-Port'
					| 'Location-Path'
					| 'Uri-Path'
					| 'Content-Format'
					| 'Max-Age'
					| 'Uri-Query'
					| 'Accept'
					| 'Location-Query'
					| 'Proxy-Uri'
					| 'Proxy-Scheme'
					| 'Size1'.
