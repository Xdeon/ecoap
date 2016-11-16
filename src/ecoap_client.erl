-module(ecoap_client).
-behaviour(gen_server).

%% API.
-export([start_link/0]).
-export([request/3, request/4, request/5, request_async/3, request_async/4, request_async/5, close/1]).

%% gen_server.
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-record(state, {
	sock_pid = undefined :: pid(),
	request_refs = undefined :: map(),
	from = undefined :: undefined | from(),
	client_pid = undefined :: pid()
}).

-include("coap_def.hrl").

-type from() :: {pid(), term()}.
-type response() :: {ok, atom(), coap_content()} | {error, atom()} | {error, atom(), coap_content()}.

%% API.

-spec start_link() -> {ok, pid()}.
start_link() ->
	gen_server:start_link(?MODULE, [self()], []).

-spec request(pid(), coap_method(), list()) -> response().
request(Pid, Method, Uri) ->
	request(Pid, Method, Uri, #coap_content{}, []).

-spec request(pid(), coap_method(), list(), coap_content()) -> response().
request(Pid, Method, Uri, Content) -> 
	request(Pid, Method, Uri, Content, []).

-spec request(pid(), coap_method(), list(), coap_content(), list(tuple())) -> response().
request(Pid, Method, Uri, Content, Options) ->
	{EpID, Path, Query} = resolve_uri(Uri),
	OptionList = [{'Uri-Path', Path}, {'Uri-Query', Query} | Options],
	start_endpoint(Pid, EpID, {Method, OptionList, Content}).

-spec request_async(pid(), coap_method(), list()) -> {ok, reference()}.
request_async(Pid, Method, Uri) ->
	request_async(Pid, Method, Uri, #coap_content{}, []).

-spec request_async(pid(), coap_method(), list(), coap_content()) -> {ok, reference()}.
request_async(Pid, Method, Uri, Content) -> 
	request_async(Pid, Method, Uri, Content, []).

-spec request_async(pid(), coap_method(), list(), coap_content(), list(tuple())) -> {ok, reference()}.
request_async(Pid, Method, Uri, Content, Options) ->
	{EpID, Path, Query} = resolve_uri(Uri),
	OptionList = [{'Uri-Path', Path}, {'Uri-Query', Query} | Options],
	ClientRef = make_ref(),
	start_endpoint_async(Pid, EpID, {Method, OptionList, Content}, ClientRef), 
	{ok, ClientRef}.

-spec close(pid()) -> ok.
close(Pid) ->
	gen_server:cast(Pid, shutdown).

start_endpoint(Pid, EpID, Req) ->
	gen_server:call(Pid, {start_endpoint, EpID, Req}, infinity).

start_endpoint_async(Pid, EpID, Req, ClientRef) -> 
	gen_server:cast(Pid, {start_endpoint, EpID, Req, ClientRef}).

%% gen_server.

init([ClientPid]) ->
	{ok, SockPid} = ecoap_socket:start_link(),
	{ok, #state{sock_pid = SockPid, request_refs = maps:new(), client_pid = ClientPid}}.

handle_call({start_endpoint, EpID, {Method, OptionList, Content}}, From, State = #state{sock_pid = SockPid, request_refs = Refs}) ->
	{ok, EndpointPid} = ecoap_socket:get_endpoint(SockPid, EpID),
	{ok, Ref} = request_block(EndpointPid, Method, OptionList, Content),
	{noreply, State#state{from = From, request_refs = store_ref(Ref, {Method, OptionList, Content, <<>>, []}, Refs)}};
handle_call(_Request, _From, State) ->
	{reply, ignored, State}.

handle_cast({start_endpoint, EpID, {Method, OptionList, Content}, ClientRef}, State = #state{sock_pid = SockPid, request_refs = Refs}) ->
	{ok, EndpointPid} = ecoap_socket:get_endpoint(SockPid, EpID),
	{ok, Ref} = request_block(EndpointPid, Method, OptionList, Content),
	{noreply, State#state{request_refs = store_ref(Ref, {Method, OptionList, Content, <<>>, ClientRef}, Refs)}};
handle_cast(shutdown, State) ->
	{stop, normal, State};
handle_cast(_Msg, State) ->
	{noreply, State}.

handle_info({coap_response, _EpID, EndpointPid, Ref, #coap_message{code={ok, 'CONTINUE'}, options=Options}}, 
	State = #state{request_refs = Refs}) ->
	case find_ref(Ref, Refs) of
		undefined -> {noreply, State};
		Req = {Method, OptionList, Content, _, _} ->
			{Num, true, Size} = coap_message_utils:get_option('Block1', Options),
    		{ok, Ref2} = request_block(EndpointPid, Method, OptionList, {Num+1, false, Size}, Content),
    		{noreply, State#state{request_refs = store_ref(Ref2, Req, delete_ref(Ref, Refs))}}
    end;
handle_info({coap_response, _EpID, EndpointPid, Ref, Message=#coap_message{code={ok, Code}, options=Options, payload=Data}}, 
	State = #state{request_refs = Refs, client_pid = ClientPid, from = From}) ->
	case find_ref(Ref, Refs) of
		undefined -> {noreply, State};
		{Method, OptionList, Content, Fragment, ClientRef} ->
			case coap_message_utils:get_option('Block2', Options) of
		            {Num, true, Size} ->
		                % more blocks follow, ask for more
		                % no payload for requests with Block2 with NUM != 0
		                {ok, Ref2} = coap_endpoint:send(EndpointPid,
		                    coap_message_utils:request('CON', Method, <<>>, [{'Block2', {Num+1, false, Size}}|OptionList])),
		                {noreply, State#state{request_refs = store_ref(Ref2, {Method, OptionList, Content, <<Fragment/binary, Data/binary>>, ClientRef}, delete_ref(Ref, Refs))}};
		            _Else ->
		                % not segmented
		                Res = return_response({ok, Code}, Message#coap_message{payload= <<Fragment/binary, Data/binary>>}),
		                ok = send_response(From, ClientPid, ClientRef, Res),
		                {noreply, State#state{request_refs = delete_ref(Ref, Refs), from = undefined}}
		    end
	end;
handle_info({coap_response, _EpID, _EndpointPid, Ref, Message=#coap_message{code=Code}}, 
	State = #state{request_refs = Refs, client_pid = ClientPid, from = From}) ->
	case find_ref(Ref, Refs) of
		undefined -> {noreply, State};
		{_, _, _, _, ClientRef}-> 
			Res = return_response(Code, Message),
		    ok = send_response(From, ClientPid, ClientRef, Res),
			{noreply, State#state{request_refs = delete_ref(Ref, Refs), from = undefined}}
	end;
handle_info({coap_error, _EpID, _EndpointPid, Ref, Error}, 
	State = #state{request_refs = Refs, client_pid = ClientPid, from = From}) ->
	case find_ref(Ref, Refs) of
		undefined -> {noreply, State};
		{_, _, _, _, ClientRef} ->
		    ok = send_response(From, ClientPid, ClientRef, {error, Error}),
			{noreply, State#state{request_refs = delete_ref(Ref, Refs), from = undefined}}
	end;
handle_info(_Info, State) ->
	{noreply, State}.

terminate(_Reason, #state{sock_pid = SockPid}) ->
	_ = [coap_endpoint:close(Pid) || Pid <- ecoap_socket:get_all_endpoints(SockPid)],
	ok = ecoap_socket:close(SockPid),
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%% Internal

find_ref(Ref, Refs) ->
	case maps:find(Ref, Refs) of
		error -> undefined;
		{ok, Val} -> Val
	end.

store_ref(Ref, Val, Refs) ->
	maps:put(Ref, Val, Refs).

delete_ref(Ref, Refs) ->
	maps:remove(Ref, Refs).

send_response(undefined, ClientPid, ClientRef, Res) ->
    ClientPid ! {ClientRef, Res},
    ok;
send_response(From, _, _, Res) ->
    _ = gen_server:reply(From, Res),
    ok.

request_block(EndpointPid, Method, ROpt, Content) ->
    request_block(EndpointPid, Method, ROpt, undefined, Content).

request_block(EndpointPid, Method, ROpt, Block1, Content) ->
    {ok, Ref} = coap_endpoint:send(EndpointPid,
        coap_message_utils:set_content(Content, Block1,
            coap_message_utils:request('CON', Method, <<>>, ROpt))),
    {ok, Ref}.

return_response({ok, Code}, Message) ->
    {ok, Code, coap_message_utils:get_content(Message)};
return_response({error, Code}, #coap_message{payload= <<>>}) ->
    {error, Code};
return_response({error, Code}, Message) ->
    {error, Code, coap_message_utils:get_content(Message)}.

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
