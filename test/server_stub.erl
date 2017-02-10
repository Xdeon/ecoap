-module(server_stub).
-behaviour(gen_server).

-include_lib("ecoap_common/include/coap_def.hrl").

%% API.
-export([start_link/1]).
-export([expect_request/2, expect_empty/3, send_empty/3, send_response/2, close/1, match/2]).

%% gen_server.
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-record(state, {
	socket = undefined :: inet:socket(),
	inbound = undefined :: undefined | coap_message(),
	peer_addr = undefined :: undefined | {inet:ip_address(), inet:port_number()}
}).

%% API.

-spec start_link(inet:port_number()) -> {ok, pid()}.
start_link(Port) ->
	gen_server:start_link(?MODULE, [Port], []).

-spec expect_request(pid(), coap_message()) -> {match, non_neg_integer(), binary()} | nomatch.
expect_request(Pid, ExpectReq) -> 
	gen_server:call(Pid, {expect_request, ExpectReq}).

-spec expect_empty(pid(), 'ACK' | 'RST', non_neg_integer()) -> match | nomatch.
expect_empty(Pid, Type, MsgId) ->
	gen_server:call(Pid, {expect_empty, Type, MsgId}).

-spec send_response(pid(), coap_message()) -> ok.
send_response(Pid, Response) ->
	gen_server:cast(Pid, {send_response, Response}).

-spec send_empty(pid(), 'ACK' | 'RST', non_neg_integer()) -> ok.
send_empty(Pid, Type, MsgId) ->
	gen_server:cast(Pid, {send_empty, Type, MsgId}).

close(Pid) ->
	gen_server:cast(Pid, shutdown).

%% gen_server.

init([Port]) ->
	{ok, Socket} = gen_udp:open(Port, [binary, {reuseaddr, true}]),
	{ok, #state{socket=Socket}}.

handle_call({expect_empty, Type, MsgId}, _From, 
	#state{inbound=#coap_message{type=Type, id=MsgId, code=undefined}}=State) ->
	{reply, match, State};
handle_call({expect_empty, _, _}, _From, State) ->
	{reply, nomatch, State};	

handle_call({expect_request, ExpectReq}, _From, #state{inbound=InBound}=State) ->
	{reply, match(ExpectReq, InBound), State};

handle_call(_Request, _From, State) ->
	{noreply, State}.

handle_cast({send_empty, Type, MsgId}, #state{socket=Socket, peer_addr={PeerIP, PeerPortNo}}=State) ->
	Response = #coap_message{type=Type, id=MsgId},
	ok = gen_udp:send(Socket, PeerIP, PeerPortNo, coap_message:encode(Response)),
	{noreply, State};
handle_cast({send_response, Response}, #state{socket=Socket, peer_addr={PeerIP, PeerPortNo}}=State) ->
	ok = gen_udp:send(Socket, PeerIP, PeerPortNo, coap_message:encode(Response)),
	{noreply, State};
handle_cast(shutdown, State) ->
	{stop, normal, State};
handle_cast(_Msg, State) ->
	{noreply, State}.

handle_info({udp, Socket, PeerIP, PeerPortNo, Bin}, #state{socket=Socket}=State) ->
	Message = coap_message:decode(Bin),
	{noreply, State#state{inbound=Message, peer_addr={PeerIP, PeerPortNo}}};

handle_info(_Info, State) ->
	{noreply, State}.

terminate(_Reason, #state{socket=Socket}) ->
	ok = gen_udp:close(Socket),
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

match(#coap_message{type=Type, code=Code, options=Options, payload=Payload},
	#coap_message{type=Type, id=MsgId, code=Code, token=Token, options=Options, payload=Payload}) ->
	{match, MsgId, Token};
match(_, _) ->
	nomatch.

