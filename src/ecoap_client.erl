-module(ecoap_client).
-behaviour(gen_server).

%% API.
-export([start_link/0]).
-export([ping/2, request/3, request/4, request/5, request_async/3, request_async/4, request_async/5, close/1]).
% -export([observe/2, observe/3, unobserve/2, unobserve/3]).

%% gen_server.
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-record(state, {
	sock_pid = undefined :: pid(),
	request_refs = undefined :: #{reference() => req()},
	client_pid = undefined :: pid()
}).

-record(req, {
	method = undefined :: undefined | coap_method(),
	option_list = undefined :: undefined | list(tuple()),
	content = undefined :: undefined | coap_content(),
	fragment = <<>> :: binary(),
	from = undefined :: undefined | from(),
	client_ref = undefined :: undefined | reference()
}).

-define(EXCHANGE_LIFETIME, 247000).

-include("coap_def.hrl").

-type from() :: {pid(), term()}.
-type req() :: #req{}.
-type response() :: {ok, atom(), coap_content()} | {error, atom()} | {error, atom(), coap_content()} | {separate, reference()}.
-type payload() :: coap_message_utils:payload().
-opaque state() :: #state{}.
-export_type([state/0]).

%% API.

-spec start_link() -> {ok, pid()}.
start_link() ->
	gen_server:start_link(?MODULE, [self()], []).

-spec ping(pid(), list()) -> ok | error.
ping(Pid, Uri) ->
	{EpID, _Path, _Query} = resolve_uri(Uri),
	case call_endpoint(Pid, {ping, EpID}) of
		{error, 'RST'} -> ok;
		_Else -> error
	end.

%% Note that options defined in Content will overwrite the same ones defined in Options
%% But if options in Content are with their default value 'undefined' then they will not be used

-spec request(pid(), coap_method(), list()) -> response().
request(Pid, Method, Uri) ->
	request(Pid, Method, Uri, #coap_content{}, []).

-spec request(pid(), coap_method(), list(), payload()) -> response().
request(Pid, Method, Uri, Content) -> 
	request(Pid, Method, Uri, Content, []).

-spec request(pid(), coap_method(), list(), payload(), list(tuple())) -> response().
request(Pid, Method, Uri, Content, Options) ->
	{EpID, Path, Query} = resolve_uri(Uri),
	OptionList = append_option({'Uri-Query', Query}, append_option({'Uri-Path', Path}, Options)),
	start_endpoint(Pid, EpID, {Method, OptionList, convert_content(Content)}).

-spec request_async(pid(), coap_method(), list()) -> {ok, reference()}.
request_async(Pid, Method, Uri) ->
	request_async(Pid, Method, Uri, #coap_content{}, []).

-spec request_async(pid(), coap_method(), list(), payload()) -> {ok, reference()}.
request_async(Pid, Method, Uri, Content) -> 
	request_async(Pid, Method, Uri, Content, []).

-spec request_async(pid(), coap_method(), list(), payload(), list(tuple())) -> {ok, reference()}.
request_async(Pid, Method, Uri, Content, Options) ->
	{EpID, Path, Query} = resolve_uri(Uri),
	OptionList = append_option({'Uri-Query', Query}, append_option({'Uri-Path', Path}, Options)),
	ClientRef = make_ref(),
	start_endpoint_async(Pid, EpID, {Method, OptionList, convert_content(Content)}, ClientRef), 
	{ok, ClientRef}.

-spec close(pid()) -> ok.
close(Pid) ->
	gen_server:call(Pid, shutdown).

start_endpoint(Pid, EpID, Req) ->
	call_endpoint(Pid, {start_endpoint, EpID, Req}).

start_endpoint_async(Pid, EpID, Req, ClientRef) -> 
	gen_server:cast(Pid, {start_endpoint, EpID, Req, ClientRef}).

%% gen_server.

init([ClientPid]) ->
	{ok, SockPid} = ecoap_socket:start_link(),
	{ok, #state{sock_pid = SockPid, request_refs = maps:new(), client_pid = ClientPid}}.

handle_call({ping, EpID}, From, State = #state{sock_pid = SockPid, request_refs = Refs}) ->
	{ok, EndpointPid} = ecoap_socket:get_endpoint(SockPid, EpID),
	{ok, Ref} = coap_endpoint:ping(EndpointPid),
	{noreply, State#state{request_refs = store_ref(Ref, #req{from=From}, Refs)}};
handle_call({start_endpoint, EpID, {Method, OptionList, Content}}, From, State = #state{sock_pid = SockPid, request_refs = Refs}) ->
	{ok, EndpointPid} = ecoap_socket:get_endpoint(SockPid, EpID),
	{ok, Ref} = request_block(EndpointPid, Method, OptionList, Content),
	{noreply, State#state{request_refs = store_ref(Ref, #req{method=Method, option_list=OptionList, content=Content, from=From}, Refs)}};
handle_call(shutdown, _From, State) ->
	{stop, normal, ok, State};
handle_call(_Request, _From, State) ->
	{reply, ignored, State}.

handle_cast({start_endpoint, EpID, {Method, OptionList, Content}, ClientRef}, State = #state{sock_pid = SockPid, request_refs = Refs}) ->
	{ok, EndpointPid} = ecoap_socket:get_endpoint(SockPid, EpID),
	{ok, Ref} = request_block(EndpointPid, Method, OptionList, Content),
	{noreply, State#state{request_refs = store_ref(Ref, #req{method=Method, option_list=OptionList, content=Content, client_ref=ClientRef}, Refs)}};
handle_cast(_Msg, State) ->
	{noreply, State}.

% response arrived as a separate CON msg
handle_info({coap_response, _EpID, EndpointPid, Ref, Message=#coap_message{type='CON'}}, State) ->
	coap_endpoint:send(EndpointPid, coap_message_utils:ack(Message)),
	handle_response(Ref, EndpointPid, Message, State);
handle_info({coap_response, _EpID, EndpointPid, Ref, Message}, State) ->
	handle_response(Ref, EndpointPid, Message, State);
% handle separate response acknowledgement
handle_info({coap_ack, _EpID, _EndpointPid, Ref}, 
	State = #state{request_refs = Refs, client_pid = ClientPid}) ->
	case find_ref(Ref, Refs) of
		undefined -> {noreply, State};
		Req = #req{client_ref=ClientRef, from=From} ->
			ok = send_response(From, ClientPid, ClientRef, {separate, Ref}),
			{noreply, State#state{request_refs = store_ref(Ref, Req#req{from = undefined, client_ref=Ref}, Refs)}}
	end;
% handle RST and timeout
handle_info({coap_error, _EpID, _EndpointPid, Ref, Error}, 
	State = #state{request_refs = Refs, client_pid = ClientPid}) ->
	case find_ref(Ref, Refs) of
		undefined -> {noreply, State};
		#req{client_ref=ClientRef, from=From} ->
		    ok = send_response(From, ClientPid, ClientRef, {error, Error}),
			{noreply, State#state{request_refs = delete_ref(Ref, Refs)}}
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

handle_response(Ref, EndpointPid, _Message=#coap_message{code={ok, 'Continue'}, options=Options}, 
	State=#state{request_refs=Refs}) ->
	case find_ref(Ref, Refs) of
		undefined -> {noreply, State};
		Req = #req{method=Method, option_list=OptionList, content=Content} ->
			{Num, true, Size} = coap_message_utils:get_option('Block1', Options),
    		{ok, Ref2} = request_block(EndpointPid, Method, OptionList, {Num+1, false, Size}, Content),
    		{noreply, State#state{request_refs = store_ref(Ref2, Req, delete_ref(Ref, Refs))}}
    end;
handle_response(Ref, EndpointPid, Message=#coap_message{code={ok, Code}, options=Options, payload=Data}, 
	State = #state{request_refs = Refs, client_pid = ClientPid}) ->
	case find_ref(Ref, Refs) of
		undefined -> {noreply, State};
		Req = #req{method=Method, option_list=OptionList, fragment=Fragment, client_ref=ClientRef, from=From} ->
			case coap_message_utils:get_option('Block2', Options) of
	            {Num, true, Size} ->
	                % more blocks follow, ask for more
	                % no payload for requests with Block2 with NUM != 0
	                {ok, Ref2} = coap_endpoint:send(EndpointPid,
	                	coap_message_utils:request('CON', Method, <<>>, append_option({'Block2', {Num+1, false, Size}}, OptionList))),
	                {noreply, State#state{request_refs = store_ref(Ref2, Req#req{fragment = <<Fragment/binary, Data/binary>>}, delete_ref(Ref, Refs))}};
	            _Else ->
	                % not segmented
	                Res = return_response({ok, Code}, Message#coap_message{payload= <<Fragment/binary, Data/binary>>}),
	                ok = send_response(From, ClientPid, ClientRef, Res),
	                {noreply, State#state{request_refs = delete_ref(Ref, Refs)}}
		    end
	end;
handle_response(Ref, _EndpointPid, Message=#coap_message{code={error, Code}}, 
	State = #state{request_refs = Refs, client_pid = ClientPid}) ->
	case find_ref(Ref, Refs) of
		undefined -> {noreply, State};
		#req{client_ref=ClientRef, from=From} -> 
			Res = return_response({error, Code}, Message),
		    ok = send_response(From, ClientPid, ClientRef, Res),
			{noreply, State#state{request_refs = delete_ref(Ref, Refs)}}
	end.

% send_notify(Ref, Req=#req{lastseq=LastSeq}, Obstate, Message=#coap_message{code={ok, Code}},
%         State=#state{client_pid=ClientPid, request_refs=Refs}) ->
%     case Obstate of
%         undefined ->
%             % subscription is terminated
%             ClientPid ! {coap_notify, self(), undefined, {ok, Code}, coap_message_utils:get_content(Message)},
%             {stop, normal, State};
%         N when LastSeq == undefined; N > LastSeq ->
%             % report and stay subscribed
%             ClientPid ! {coap_notify, self(), N, {ok, Code}, coap_message_utils:get_content(Message)},
%             {noreply, State#state{request_refs = store_ref(Ref, Req#req{lastseq=N}, Refs)}};
%         N when N =< LastSeq ->
%             % ignore, but stay subscribed
%             {noreply, State}
%     end;
% send_notify(_Ref, _Req, _Obstate, Message=#coap_message{code={error, Code}},
% 	State=#state{client_pid=ClientPid}) ->
% 	ClientPid ! {coap_notify, self(), undefined, {error, Code}, coap_message_utils:get_content(Message)},
%     {stop, normal, State}.
	
call_endpoint(Pid, Msg) ->
	gen_server:call(Pid, Msg, ?EXCHANGE_LIFETIME).

append_option({Option, Value}, Options) ->
	lists:keystore(Option, 1, Options, {Option, Value}).

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
    ClientPid ! {async_response, self(), ClientRef, Res},
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

convert_content(Content = #coap_content{}) -> Content;
convert_content(Content) when is_binary(Content) -> #coap_content{payload=Content};
convert_content(Content) when is_list(Content) -> #coap_content{payload=list_to_binary(Content)}.

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
