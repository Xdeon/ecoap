% This module provide a simple synchronous CoAP client
% Each request is made in a pair of newly-spawned ecoap_udp_socket and ecoap_endpoint processes synchronously
% After a request is completed, related processes are automatically shut down
% It aims at simplicity for use without need for starting, terminating and managing process manually
% Thus it can not be used as an OTP-compliant component
% It also does not support separate response in favour of simplicity and to avoid race condition
% The result of a separate responsed resource is, however, depends on the time it takes to finish (may lead up to an infinity waiting)
% But note that there will not be any empty ACK to a separate CON response since everything has been shutdown after receiving
% This module only supports sending confirmable requests

-module(ecoap_simple_client).
-behaviour(gen_server).

%% API.
-export([start_link/0, close/1]).
-export([ping/1, request/2, request/3, request/4]).

%% gen_server.
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-record(state, {
	sock_pid = undefined :: undefined | pid(),
	endpoint_pid = undefined :: undefined | pid(),
	ref = undefined :: undefined | reference(),
	req = undefined :: undefined | req(),
	from = undefined :: undefined | from()
}).

-record(req, {
	method = undefined :: coap_message:coap_method(),
	options = undefined :: coap_message:optionset(),
	content = undefined :: binary(),
	fragment = <<>> :: binary()
}).

-type from() :: {pid(), term()}.
-type req() :: #req{}.
-type response() :: {ok, coap_message:success_code(), coap_content:coap_content()} | 
					{error, timeout} |
					{error, coap_message:error_code()} | 
					{error, coap_message:error_code(), coap_content:coap_content()}.
-opaque state() :: #state{}.
-export_type([state/0]).

-include("ecoap.hrl").

%% API.

-spec start_link() -> {ok, pid()}.
start_link() ->
	gen_server:start_link(?MODULE, [], []).

-spec close(pid()) -> ok.
close(Pid) -> 
	gen_server:stop(Pid).

-spec ping(string()) -> ok | error.
ping(Uri) ->
	{ok, Pid} = start_link(),
	{_Scheme, _Host, EpID, _Path, _Query} = ecoap_uri:decode_uri(Uri),
	Res = case send_request(Pid, EpID, ping) of
		{error, 'RST'} -> ok;
		_Else -> error
	end,
	ok = close(Pid),
	Res.

-spec request(coap_message:coap_method(), string()) -> response().
request(Method, Uri) ->
	request(Method, Uri, <<>>, #{}).

-spec request(coap_message:coap_method(), string(), binary()) -> response().
request(Method, Uri, Content) ->
	request(Method, Uri, Content, #{}).	

-spec request(coap_message:coap_method(), string(), binary(), coap_message:optionset()) -> response().
request(Method, Uri, Content, Options) ->
	{ok, Pid} = start_link(),
	{EpID, Req} = assemble_request(Method, Uri, Options, Content),
	Res = send_request(Pid, EpID, Req),
	ok = close(Pid),
	Res.

%% gen_server.

init([]) ->
	{ok, #state{}}.

handle_call({send_request, EpID, ping}, From, State) -> 
	{ok, SockPid} = ecoap_udp_socket:start_link(),
	{ok, EndpointPid} = ecoap_udp_socket:get_endpoint(SockPid, EpID),
	{ok, Ref} = ecoap_endpoint:ping(EndpointPid),
	{noreply, State#state{sock_pid=SockPid, endpoint_pid=EndpointPid, ref=Ref, from=From}};

handle_call({send_request, EpID, {Method, Options, Content}}, From, State) ->
	{ok, SockPid} = ecoap_udp_socket:start_link(),
	{ok, EndpointPid} = ecoap_udp_socket:get_endpoint(SockPid, EpID),
	{ok, Ref} = request_block(EndpointPid, Method, Options, Content),
	Req = #req{method=Method, options=Options, content=Content},
	{noreply, State#state{sock_pid=SockPid, endpoint_pid=EndpointPid, ref=Ref, req=Req, from=From}};

handle_call(_Request, _From, State) ->
	{noreply, State}.

handle_cast(_Msg, State) ->
	{noreply, State}.

% Notice that because we use synchronous call here and in order to avoid race condition, separate response is not supported
handle_info({coap_response, _EpID, EndpointPid, Ref, Message}, State=#state{ref=Ref}) ->
	handle_response(EndpointPid, Message, State);

% handle RST and timeout
handle_info({coap_error, _EpID, _EndpointPid, Ref, Error}, 
	State=#state{ref=Ref, from=From}) ->
	ok = send_response(From, {error, Error}), 
	{noreply, State#state{ref=undefined}};

handle_info(_Info, State) ->
	{noreply, State}.

terminate(_Reason, _State=#state{sock_pid=SockPid}) ->
	ok = ecoap_udp_socket:close(SockPid),
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%% Internal

send_request(Pid, EpID, Req) ->
	gen_server:call(Pid, {send_request, EpID, Req}, infinity).

assemble_request(Method, Uri, Options, Content) ->
	{_Scheme, Host, {PeerIP, PortNo}, Path, Query} = ecoap_uri:decode_uri(Uri),
	Options2 = coap_message:add_option('Uri-Path', Path, 
					coap_message:add_option('Uri-Query', Query,
						coap_message:add_option('Uri-Host', Host, 
							coap_message:add_option('Uri-Port', PortNo, Options)))),
	{{PeerIP, PortNo}, {Method, Options2, Content}}.

request_block(EndpointPid, Method, ROpt, Content) ->
    request_block(EndpointPid, Method, ROpt, undefined, Content).

request_block(EndpointPid, Method, ROpt, Block1, Content) ->
    ecoap_endpoint:send(EndpointPid, ecoap_request:set_payload(Content, Block1,
        ecoap_request:request('CON', Method, ROpt))).

% handle_response(EndpointPid, _Message=#{code:={ok, 'Continue'}, options:=Options1}, 
% 	State=#state{req=#req{method=Method, options=Options2, content=Content}}) ->
% 	{Num, true, Size} = coap_message:get_option('Block1', Options1),
% 	{ok, Ref2} = request_block(EndpointPid, Method, Options2, {Num+1, false, Size}, Content),
% 	{noreply, State#state{ref=Ref2}};

% handle_response(EndpointPid, Message=#{code:={ok, Code}, options:=Options1, payload:=Data}, 
% 	State=#state{endpoint_pid=EndpointPid, 
% 		req=Req=#req{method=Method, options=Options2, fragment=Fragment}, from=From}) ->
% 	case coap_message:get_option('Block2', Options1) of
%         {Num, true, Size} ->
%          	% more blocks follow, ask for more
%             % no payload for requests with Block2 with NUM != 0
%         	{ok, Ref2} = ecoap_endpoint:send(EndpointPid,
%             	ecoap_request:request('CON', Method, coap_message:add_option('Block2', {Num+1, false, Size}, Options2))),
% 				{noreply, State#state{ref=Ref2, req=Req#req{fragment= <<Fragment/binary, Data/binary>>}}};
% 		 _Else ->
% 		 	Res = return_response({ok, Code}, Message#{payload:= <<Fragment/binary, Data/binary>>}),
% 		 	ok = send_response(From, Res),
% 		 	{noreply, State#state{ref=undefined}}
%     end;

% handle_response(_EndpointPid, Message=#{code:={error, Code}}, 
% 	State=#state{from=From}) ->
% 	Res = return_response({error, Code}, Message),
% 	ok = send_response(From, Res),
% 	{noreply, State#state{ref=undefined}}.

handle_response(EndpointPid, Message, 
	State=#state{req=Req=#req{method=Method, options=Options2, content=Content, fragment=Fragment}, from=From}) ->
	case coap_message:get_code(Message) of
		{ok, 'Continue'} ->
			{Num, true, Size} = coap_message:get_option('Block1', Message),
			{ok, Ref2} = request_block(EndpointPid, Method, Options2, {Num+1, false, Size}, Content),
			{noreply, State#state{ref=Ref2}};
		{ok, Code} ->
			Data = coap_message:get_payload(Message),
			case coap_message:get_option('Block2', Message) of
		        {Num, true, Size} ->
		         	% more blocks follow, ask for more
		            % no payload for requests with Block2 with NUM != 0
		        	{ok, Ref2} = ecoap_endpoint:send(EndpointPid,
		            	ecoap_request:request('CON', Method, coap_message:add_option('Block2', {Num+1, false, Size}, Options2))),
						{noreply, State#state{ref=Ref2, req=Req#req{fragment= <<Fragment/binary, Data/binary>>}}};
				 _Else ->
				 	Res = return_response({ok, Code}, coap_message:set_payload(<<Fragment/binary, Data/binary>>, Message)),
				 	ok = send_response(From, Res),
				 	{noreply, State#state{ref=undefined}}
		    end;
		{error, Code} ->
			Res = return_response({error, Code}, Message),
			ok = send_response(From, Res),
			{noreply, State#state{ref=undefined}}
	end.

send_response(From, Res) ->
	_ = gen_server:reply(From, Res),
	ok.

return_response({ok, Code}, Message) ->
    {ok, Code, coap_content:get_content(Message)};
return_response({error, Code}, Message) ->
	case coap_message:get_payload(Message) of
		<<>> -> {error, Code};
		_ -> {error, Code, coap_content:get_content(Message)}
	end.