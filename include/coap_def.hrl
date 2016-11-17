-define(DEFAULT_MAX_AGE, 60).
-define(MAX_BLOCK_SIZE, 1024).

-record(coap_message, {
	type = undefined :: coap_type(), 
	code = undefined :: undefined | coap_code(), 
	id = undefined :: undefined | 0..65535, 
	token = <<>> :: binary(),
	options = [] :: list(tuple()), 
	payload = <<>> :: binary()
}).

-type coap_message() :: #coap_message{}.

-record(coap_content, {
	etag = undefined :: undefined | binary(),
	max_age = ?DEFAULT_MAX_AGE :: non_neg_integer(),
	format = undefined :: undefined | binary(),
	payload = <<>> :: binary()
}).

-type coap_content() :: #coap_content{}.

-type coap_type() :: 'CON' | 'NON' | 'ACK' | 'RST' .
-type coap_method() :: 'GET' | 'POST' | 'PUT' | 'DELETE'.
-type coap_success() :: {ok, 'Created' | 'Deleted' | 'Valid' | 'Changed' | 'Content' | 'Continue'}. 
-type coap_error() :: {error, 'BadRequest' 
							| 'Unauthorized' 
							| 'BadOption' 
							| 'Forbidden' 
							| 'NotFound' 
							| 'MethodNotAllowed' 
							| 'NotAcceptable' 
							| 'RequestEntityIncomplete' 
							| 'PreconditionFailed' 
							| 'RequestEntityTooLarge' 
							| 'UnsupportedContentFormat' 
							| 'InternalServerError' 
							| 'NotImplemented' 
							| 'BadGateway' 
							| 'ServiceUnavailable' 
							| 'GatewayTimeout' 
							| 'ProxyingNotSupported'}.
-type coap_code() :: coap_method() | coap_success() | coap_error().

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



