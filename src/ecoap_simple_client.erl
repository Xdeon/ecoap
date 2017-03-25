% This module provide a simple synchronous CoAP client
% Each request is made in a pair of newly-opened ecoap_udp_socket and coap_endpoint processes synchronously
% After a request is completed, related processes are automatically shut down
% It aims at simplicity for use without need for starting, terminating and managing process manually
% Thus it can not be used as an OTP-compliant component
% It also does not support separate response in favour of simplicity and to avoid race condition
% The result of a separate responsed resource is, however, depends on the time it takes to finish
% If it is finished within 247s than it will appear as a synchronous response that just takes a bit longer to complete
% If it is beyond 247s than the request will finally times out
% But note that there will not be any empty ACK to a separate CON response since everything has been shutdown after receiving

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
	method = undefined :: coap_method(),
	options = undefined :: optionset(),
	content = undefined :: coap_content(),
	fragment = <<>> :: binary()
}).

-type from() :: {pid(), term()}.
-type req() :: #req{}.
-type request_content() :: binary().
-type response() :: {ok, success_code(), coap_content()} | 
					{ok, success_code(), coap_content(), optionset()} | 
					{error, error_code()} | 
					{error, error_code(), coap_content()} | 
					{separate, reference()}.
-opaque state() :: #state{}.
-export_type([state/0]).

-include_lib("ecoap_common/include/coap_def.hrl").

%% API.

-spec start_link() -> {ok, pid()}.
start_link() ->
	gen_server:start_link(?MODULE, [], []).

-spec close(pid()) -> ok.
close(Pid) -> 
	gen_server:cast(Pid, shutdown).

-spec ping(list()) -> ok | error.
ping(Uri) ->
	{ok, Pid} = start_link(),
	{EpID, _Path, _Query} = resolve_uri(Uri),
	Res = case send_request(Pid, EpID, ping) of
		{error, 'RST'} -> ok;
		_Else -> error
	end,
	ok = close(Pid),
	Res.

-spec request(coap_method(), list()) -> response().
request(Method, Uri) ->
	request(Method, Uri, <<>>, []).

-spec request(coap_method(), list(), request_content()) -> response().
request(Method, Uri, Content) ->
	request(Method, Uri, Content, []).	

-spec request(coap_method(), list(), request_content(), optionset()) -> response().
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
	{ok, Ref} = coap_endpoint:ping(EndpointPid),
	{noreply, State#state{sock_pid=SockPid, endpoint_pid=EndpointPid, ref=Ref, from=From}};

handle_call({send_request, EpID, {Method, Options, Content}}, From, State) ->
	{ok, SockPid} = ecoap_udp_socket:start_link(),
	{ok, EndpointPid} = ecoap_udp_socket:get_endpoint(SockPid, EpID),
	{ok, Ref} = request_block(EndpointPid, Method, Options, Content),
	Req = #req{method=Method, options=Options, content=Content},
	{noreply, State#state{sock_pid=SockPid, endpoint_pid=EndpointPid, ref=Ref, req=Req, from=From}};

handle_call(_Request, _From, State) ->
	{noreply, State}.

handle_cast(shutdown, State) ->
	{stop, normal, State};
handle_cast(_Msg, State) ->
	{noreply, State}.

% Notice that because we use synchronous call here and in order to avoid race condition, separate response is not supported
handle_info({coap_response, _EpID, EndpointPid, Ref, Message}, State=#state{ref=Ref}) ->
	handle_response(EndpointPid, Message, State);

% handle RST and timeout
handle_info({coap_error, _EpID, _EndpointPid, Ref, Error}, 
	State=#state{ref=Ref, from=From}) ->
	ok = send_response(From, {error, Error}), 
	{noreply, State};

handle_info(_Info, State) ->
	{noreply, State}.

terminate(_Reason, _State=#state{sock_pid=SockPid, endpoint_pid=EndpointPid}) ->
	ok = close_transport(SockPid, EndpointPid),
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%% Internal

send_request(Pid, EpID, Req) ->
	gen_server:call(Pid, {send_request, EpID, Req}, infinity).

assemble_request(Method, Uri, Options, Content) ->
	{EpID, Path, Query} = resolve_uri(Uri),
	Options2 = coap_utils:add_option('Uri-Query', Query, coap_utils:add_option('Uri-Path', Path, Options)),
	{EpID, {Method, Options2, #coap_content{payload=Content}}}.

request_block(EndpointPid, Method, ROpt, Content) ->
    request_block(EndpointPid, Method, ROpt, undefined, Content).

request_block(EndpointPid, Method, ROpt, Block1, Content) ->
    coap_endpoint:send(EndpointPid, coap_utils:set_content(Content, Block1,
        coap_utils:request('CON', Method, <<>>, ROpt))).

handle_response(EndpointPid, _Message=#coap_message{code={ok, 'Continue'}, options=Options1}, 
	State=#state{req=#req{method=Method, options=Options2, content=Content}}) ->
	{Num, true, Size} = coap_utils:get_option('Block1', Options1),
	{ok, Ref2} = request_block(EndpointPid, Method, Options2, {Num+1, false, Size}, Content),
	{noreply, State#state{ref=Ref2}};

handle_response(EndpointPid, Message=#coap_message{code={ok, Code}, options=Options1, payload=Data}, 
	State=#state{endpoint_pid=EndpointPid, 
		req=Req=#req{method=Method, options=Options2, fragment=Fragment}, from=From}) ->
	case coap_utils:get_option('Block2', Options1) of
        {Num, true, Size} ->
         	% more blocks follow, ask for more
            % no payload for requests with Block2 with NUM != 0
        	{ok, Ref2} = coap_endpoint:send(EndpointPid,
            	coap_utils:request('CON', Method, <<>>, coap_utils:add_option('Block2', {Num+1, false, Size}, Options2))),
				{noreply, State#state{ref=Ref2, req=Req#req{fragment= <<Fragment/binary, Data/binary>>}}};
		 _Else ->
		 	Res = return_response({ok, Code}, Message#coap_message{payload= <<Fragment/binary, Data/binary>>}),
		 	ok = send_response(From, Res),
		 	{noreply, State}
    end;

handle_response(_EndpointPid, Message=#coap_message{code={error, Code}}, 
	State=#state{from=From}) ->
	Res = return_response({error, Code}, Message),
	ok = send_response(From, Res),
	{noreply, State}.

send_response(From, Res) ->
	_ = gen_server:reply(From, Res),
	ok.

return_response({ok, Code}, Message) ->
    {ok, Code, coap_utils:get_content(Message), coap_utils:get_extra_options(Message)};
return_response({error, Code}, #coap_message{payload= <<>>}) ->
    {error, Code};
return_response({error, Code}, Message) ->
    {error, Code, coap_utils:get_content(Message)}.

close_transport(SockPid, EndpointPid) ->
	coap_endpoint:close(EndpointPid),
	ecoap_udp_socket:close(SockPid).

resolve_uri(Uri) ->
    {ok, {_Scheme, _UserInfo, Host, PortNo, Path, Query}} =
        http_uri:parse(Uri, [{scheme_defaults, [{coap, 5683}]}]),
    {ok, PeerIP} = inet:getaddr(Host, inet),
    {{PeerIP, PortNo}, split_path(Path), split_query(Query)}.

split_path([]) -> [];
split_path([$/]) -> [];
split_path([$/ | Path]) -> split_segments(Path, $/, []).

split_query([]) -> [];
split_query([$? | Path]) -> split_segments(Path, $&, []).

split_segments(Path, Char, Acc) ->
    case string:rchr(Path, Char) of
        0 ->
            [make_segment(Path) | Acc];
        N when N > 0 ->
            split_segments(string:substr(Path, 1, N-1), Char,
                [make_segment(string:substr(Path, N+1)) | Acc])
    end.

make_segment(Seg) ->
    list_to_binary(http_uri:decode(Seg)).
