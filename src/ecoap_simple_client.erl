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
	method = undefined :: ecoap_message:coap_method(),
	options = undefined :: ecoap_message:optionset(),
	content = undefined :: binary(),
	fragment = <<>> :: binary()
}).

-type from() :: {pid(), term()}.
-type req() :: #req{}.
-type response() :: {ok, ecoap_message:success_code(), ecoap_content:ecoap_content()} | 
					{error, timeout} |
					{error, ecoap_message:error_code()} | 
					{error, ecoap_message:error_code(), ecoap_content:ecoap_content()}.
-opaque state() :: #state{}.
-export_type([state/0]).

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
	#{ip:=IP, port:=Port} = ecoap_uri:decode_uri(Uri),
	Res = case send_request(Pid, {IP, Port}, ping) of
		{error, 'RST'} -> ok;
		_Else -> error
	end,
	ok = close(Pid),
	Res.

-spec request(ecoap_message:coap_method(), string()) -> response().
request(Method, Uri) ->
	request(Method, Uri, <<>>, #{}).

-spec request(ecoap_message:coap_method(), string(), binary()) -> response().
request(Method, Uri, Content) ->
	request(Method, Uri, Content, #{}).	

-spec request(ecoap_message:coap_method(), string(), binary(), ecoap_message:optionset()) -> response().
request(Method, Uri, Content, Options) ->
	{ok, Pid} = start_link(),
	{EpAddr, Req} = assemble_request(Method, Uri, Options, Content),
	Res = send_request(Pid, EpAddr, Req),
	ok = close(Pid),
	Res.

%% gen_server.

init([]) ->
	{ok, #state{}}.

handle_call({send_request, EpAddr, ping}, From, State) -> 
	{ok, SockPid} = ecoap_udp_socket:connect(EpAddr, [], #{}, infinity),
	{ok, EndpointPid} = ecoap_udp_socket:get_endpoint(SockPid, EpAddr),
	{ok, Ref} = ecoap_endpoint:ping(EndpointPid),
	{noreply, State#state{sock_pid=SockPid, endpoint_pid=EndpointPid, ref=Ref, from=From}};

handle_call({send_request, EpAddr, {Method, Options, Content}}, From, State) ->
	{ok, SockPid} = ecoap_udp_socket:connect(EpAddr, [], #{}, infinity),
	{ok, EndpointPid} = ecoap_udp_socket:get_endpoint(SockPid, EpAddr),
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
	#{host:=Host, ip:=IP, port:=Port, path:=Path, 'query':=Query} = ecoap_uri:decode_uri(Uri),
	Options2 = ecoap_message:add_option('Uri-Path', Path, 
					ecoap_message:add_option('Uri-Query', Query,
						ecoap_message:add_option('Uri-Host', Host, 
							ecoap_message:add_option('Uri-Port', Port, Options)))),
	{{IP, Port}, {Method, Options2, Content}}.

request_block(EndpointPid, Method, ROpt, Content) ->
    request_block(EndpointPid, Method, ROpt, undefined, Content).

request_block(EndpointPid, Method, ROpt, Block1, Content) ->
    ecoap_endpoint:send(EndpointPid, ecoap_request:set_payload(Content, Block1,
        ecoap_request:request('CON', Method, ROpt))).

% handle_response(EndpointPid, _Message=#{code:={ok, 'Continue'}, options:=Options1}, 
% 	State=#state{req=#req{method=Method, options=Options2, content=Content}}) ->
% 	{Num, true, Size} = ecoap_message:get_option('Block1', Options1),
% 	{ok, Ref2} = request_block(EndpointPid, Method, Options2, {Num+1, false, Size}, Content),
% 	{noreply, State#state{ref=Ref2}};

% handle_response(EndpointPid, Message=#{code:={ok, Code}, options:=Options1, payload:=Data}, 
% 	State=#state{endpoint_pid=EndpointPid, 
% 		req=Req=#req{method=Method, options=Options2, fragment=Fragment}, from=From}) ->
% 	case ecoap_message:get_option('Block2', Options1) of
%         {Num, true, Size} ->
%          	% more blocks follow, ask for more
%             % no payload for requests with Block2 with NUM != 0
%         	{ok, Ref2} = ecoap_endpoint:send(EndpointPid,
%             	ecoap_request:request('CON', Method, ecoap_message:add_option('Block2', {Num+1, false, Size}, Options2))),
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
	case ecoap_message:get_code(Message) of
		{ok, 'Continue'} ->
			{Num, true, Size} = ecoap_message:get_option('Block1', Message),
			{ok, Ref2} = request_block(EndpointPid, Method, Options2, {Num+1, false, Size}, Content),
			{noreply, State#state{ref=Ref2}};
		{ok, Code} ->
			Data = ecoap_message:get_payload(Message),
			case ecoap_message:get_option('Block2', Message) of
		        {Num, true, Size} ->
		         	% more blocks follow, ask for more
		            % no payload for requests with Block2 with NUM != 0
		        	{ok, Ref2} = ecoap_endpoint:send(EndpointPid,
		            	ecoap_request:request('CON', Method, ecoap_message:add_option('Block2', {Num+1, false, Size}, Options2))),
						{noreply, State#state{ref=Ref2, req=Req#req{fragment= <<Fragment/binary, Data/binary>>}}};
				 _Else ->
				 	Res = return_response({ok, Code}, ecoap_message:set_payload(<<Fragment/binary, Data/binary>>, Message)),
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
    {ok, Code, ecoap_content:get_content(Message)};
return_response({error, Code}, Message) ->
	case ecoap_message:get_payload(Message) of
		<<>> -> {error, Code};
		_ -> {error, Code, ecoap_content:get_content(Message)}
	end.