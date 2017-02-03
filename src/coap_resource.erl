%
% The contents of this file are subject to the Mozilla Public License
% Version 1.1 (the "License"); you may not use this file except in
% compliance with the License. You may obtain a copy of the License at
% http://www.mozilla.org/MPL/
%
% Copyright (c) 2015 Petr Gotthard <petr.gotthard@centrum.cz>
%

-module(coap_resource).

-include("coap_def.hrl").

-type coap_endpoint_id() :: coap_endpoint:coap_endpoint_id().
-type coap_uri() :: core_link:coap_uri().

% called when a client asks for .well-known/core resources
-callback coap_discover(Prefix, Args) -> [Uri] when
	Prefix :: [binary()],
	Args :: any(),
	Uri :: coap_uri().

% GET handler
-callback coap_get(EpID, Prefix, Name, Query, Accept) -> Content | Error when
	EpID :: coap_endpoint_id(),
	Prefix :: [binary()],
	Name :: [binary()],
	Query :: [binary()],
	Accept :: binary() | non_neg_integer(),
	Content :: coap_content(),
	Error :: coap_error().

% POST handler
-callback coap_post(EpID, Prefix, Name, RequestContent) -> {ok, Code, ResponseContent} | Error when
	EpID :: coap_endpoint_id(),
	Prefix :: [binary()],
	Name :: [binary()],
	RequestContent :: coap_content(),
	Code :: success_code(),
	ResponseContent :: coap_content(),
	Error :: coap_error().

% PUT handler
-callback coap_put(EpID, Prefix, Name, RequestContent) -> ok | Error when
	EpID :: coap_endpoint_id(),
	Prefix :: [binary()],
	Name :: [binary()],
	RequestContent :: coap_content(),
	Error :: coap_error().

% DELETE handler
-callback coap_delete(EpID, Prefix, Name) -> ok | Error when
	EpID :: coap_endpoint_id(),
	Prefix :: [binary()],
	Name :: [binary()],
	Error :: coap_error().

% observe request handler
-callback coap_observe(EpID, Prefix, Name, NeedAck) -> {ok, Obstate} | Error when
	EpID :: coap_endpoint_id(),
	Prefix :: [binary()],
	Name :: [binary()],
	NeedAck :: boolean(),
	Obstate :: any(),
	Error :: coap_error().

% cancellation request handler
-callback coap_unobserve(Obstate) -> ok when
	Obstate :: any().

% handler for messages sent to the responder process
% used to generate notifications
-callback handle_info(Info, Obstate) -> 
	{notify, Ref, Content|Error, NewObstate} | {noreply, NewObstate} | {stop, NewObstate} when
	Info :: any(),
	Obstate :: any(),
	Ref :: any(),
	Content :: coap_content(),
	Error :: coap_error(),
	NewObstate :: any().

% response to notifications
-callback coap_ack(Ref, Obstate) -> {ok, NewObstate} when
	Ref :: any(),
	Obstate :: any(),
	NewObstate :: any().

% end of file
