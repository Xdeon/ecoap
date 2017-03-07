%
% The contents of this file are subject to the Mozilla Public License
% Version 1.1 (the "License"); you may not use this file except in
% compliance with the License. You may obtain a copy of the License at
% http://www.mozilla.org/MPL/
%
% Copyright (c) 2015 Petr Gotthard <petr.gotthard@centrum.cz>
%

-module(coap_resource).

-include_lib("ecoap_common/include/coap_def.hrl").

-type coap_endpoint_id() :: ecoap_socket:coap_endpoint_id().
-type coap_uri() :: core_link:coap_uri().

% called when a client asks for .well-known/core resources
-callback coap_discover(Prefix, Args) -> [Uri] when
	Prefix :: [binary()],
	Args :: any(),
	Uri :: coap_uri().

% GET handler
-callback coap_get(EpID, Prefix, Name, Query, Request) -> {ok, Content, Options} | {error, Error} | {error, Error, Reason} when
	EpID :: coap_endpoint_id(),
	Prefix :: [binary()],
	Name :: [binary()],
	Query :: [binary()],
	Request :: coap_message(),
	Content :: coap_content(),
	Options :: optionset(),
	Error :: error_code(),
	Reason :: binary().

% POST handler
-callback coap_post(EpID, Prefix, Name, Request) -> {ok, Code, Content, Options} | {error, Error} | {error, Error, Reason} when
	EpID :: coap_endpoint_id(),
	Prefix :: [binary()],
	Name :: [binary()],
	Request :: coap_message(),
	Code :: success_code(),
	Content :: coap_content(),
	Options :: optionset(),
	Error :: error_code(),
	Reason :: binary().

% PUT handler
-callback coap_put(EpID, Prefix, Name, Request) -> ok | {error, Error} | {error, Error, Reason} when
	EpID :: coap_endpoint_id(),
	Prefix :: [binary()],
	Name :: [binary()],
	Request :: coap_message(),
	Error :: error_code(),
	Reason :: binary().

% DELETE handler
-callback coap_delete(EpID, Prefix, Name, Request) -> ok | {error, Error} | {error, Error, Reason} when
	EpID :: coap_endpoint_id(),
	Prefix :: [binary()],
	Name :: [binary()],
	Request :: coap_message(),
	Error :: error_code(),
	Reason :: binary().

% observe request handler
-callback coap_observe(EpID, Prefix, Name, Request) -> {ok, Obstate} | {error, Error} | {error, Error, Reason} when
	EpID :: coap_endpoint_id(),
	Prefix :: [binary()],
	Name :: [binary()],
	Request :: coap_message(),
	Obstate :: any(),
	Error :: error_code(),
	Reason :: binary().

% cancellation request handler
-callback coap_unobserve(Obstate) -> ok when
	Obstate :: any().

% handler for messages sent to the responder process
% used to generate notifications
-callback handle_info(Info, Obstate) -> 
	{notify, Ref, Content, Options, NewObstate} | 
	{notify, Ref, {error, Error}, NewObstate} | 
	{noreply, NewObstate} | 
	{stop, NewObstate} when
	Info :: any(),
	Obstate :: any(),
	Ref :: any(),
	Content :: coap_content(),
	Options :: optionset(),
	Error :: error_code(),
	NewObstate :: any().

% response to notifications
-callback coap_ack(Ref, Obstate) -> {ok, NewObstate} when
	Ref :: any(),
	Obstate :: any(),
	NewObstate :: any().

% end of file
