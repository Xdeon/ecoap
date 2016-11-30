-define(DEFAULT_MAX_AGE, 60).

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
	format = undefined :: undefined | binary() | non_neg_integer(),
	payload = <<>> :: binary()
}).

-type coap_content() :: #coap_content{}.

-type coap_type() :: 'CON' | 'NON' | 'ACK' | 'RST' .

-type coap_method() :: 'GET' | 'POST' | 'PUT' | 'DELETE'.

-type success_code() :: 'Created' | 'Deleted' | 'Valid' | 'Changed' | 'Content' | 'Continue'.

-type error_code() :: 'BadRequest' 
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
					| 'ProxyingNotSupported'.

-type coap_success() :: {ok, success_code()}. 

-type coap_error() :: {error, error_code()}.

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
