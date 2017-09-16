-module(coap_resource).

-type ecoap_endpoint_id() :: ecoap_udp_socket:ecoap_endpoint_id().
-type coap_uri() :: core_link:coap_uri().

% called when a client asks for .well-known/core resources
-callback coap_discover(Prefix, Args) -> [Uri] when
	Prefix :: [binary()],
	Args :: any(),
	Uri :: coap_uri().

% GET handler
-callback coap_get(EpID, Prefix, Name, Query, Request) -> 
	{ok, Payload} | {ok, Payload, Options} | {error, Error} | {error, Error, Reason} when
	EpID :: ecoap_endpoint_id(),
	Prefix :: [binary()],
	Name :: [binary()],
	Query :: [binary()],
	Request :: coap_message:coap_message(),
	Payload :: binary(),
	Options :: coap_message:optionset(),
	Error :: coap_message:error_code(),
	Reason :: binary().

% POST handler
-callback coap_post(EpID, Prefix, Name, Request) -> 
	{ok, Code, Payload} | {ok, Code, Payload, Options} | {error, Error} | {error, Error, Reason} when
	EpID :: ecoap_endpoint_id(),
	Prefix :: [binary()],
	Name :: [binary()],
	Request :: coap_message:coap_message(),
	Code :: coap_message:success_code(),
	Payload :: binary(),
	Options :: coap_message:optionset(),
	Error :: coap_message:error_code(),
	Reason :: binary().

% PUT handler
-callback coap_put(EpID, Prefix, Name, Request) -> ok | {error, Error} | {error, Error, Reason} when
	EpID :: ecoap_endpoint_id(),
	Prefix :: [binary()],
	Name :: [binary()],
	Request :: coap_message:coap_message(),
	Error :: coap_message:error_code(),
	Reason :: binary().

% DELETE handler
-callback coap_delete(EpID, Prefix, Name, Request) -> ok | {error, Error} | {error, Error, Reason} when
	EpID :: ecoap_endpoint_id(),
	Prefix :: [binary()],
	Name :: [binary()],
	Request :: coap_message:coap_message(),
	Error :: coap_message:error_code(),
	Reason :: binary().

% observe request handler
-callback coap_observe(EpID, Prefix, Name, Request) -> {ok, Obstate} | {error, Error} | {error, Error, Reason} when
	EpID :: ecoap_endpoint_id(),
	Prefix :: [binary()],
	Name :: [binary()],
	Request :: coap_message:coap_message(),
	Obstate :: any(),
	Error :: coap_message:error_code(),
	Reason :: binary().

% cancellation request handler
-callback coap_unobserve(Obstate) -> ok when
	Obstate :: any().

% handler for outgoing notifications generated by calling ecoap_handler:notify/2
% one can check Content-Format of notifications according to original observe request ObsReq 
% and may return {ok, {error, 'NotAcceptable'}, State} if the format can not be provided anymore
-callback handle_notify(Info, ObsReq, Obstate) -> 
	{ok, Payload, NewObstate} | {ok, Payload, Options, NewObstate} | {ok, {error, Error}, NewObstate} when
	Info :: any(),
	ObsReq :: coap_message:coap_message(),
	Obstate :: any(),
	Payload :: binary(),
	Options :: coap_message:optionset(),
	Error :: coap_message:error_code(),
	NewObstate :: any().

% handler for messages sent to the coap_handler process
% could be used to generate notifications
% the function can be used to generate tags which correlate outgoing CON notifications with incoming ACKs
-callback handle_info(Info, ObsReq, Obstate) -> 
	{notify, Ref, Payload, NewObstate} | 
	{notify, Ref, Payload, Options, NewObstate} |
	{notify, Ref, {error, Error}, NewObstate} |
	{noreply, NewObstate} | 
	{stop, NewObstate} when
	Info :: any(),
	ObsReq :: coap_message:coap_message(),
	Obstate :: any(),
	Ref :: any(),
	Payload :: binary(),
	Options :: coap_message:optionset(),
	Error :: coap_message:error_code(),
	NewObstate :: any().

% response to notifications
-callback coap_ack(Ref, Obstate) -> {ok, NewObstate} when
	Ref :: any(),
	Obstate :: any(),
	NewObstate :: any().

% end of file
