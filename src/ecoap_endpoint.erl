-module(ecoap_endpoint).
-behaviour(gen_server).

%% API.
-export([start_link/5, start_link/4]).
-export([ping/1, ping/2, send/2, send_message/3, send_request/3, send_response/3, cancel_request/2]).
-export([register_handler/3]).
-export([get_peer_info/2]).

%% gen_server.
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_continue/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-define(VERSION, 1).

-define(SCAN_INTERVAL, 10000). % scan every 10s

-record(state, {
    protocol_config = undefined :: ecoap_config:protocol_config(),
	tokens = #{} :: #{coap_message:token() => receiver()},
	trans = #{} :: #{trid() => ecoap_exchange:exchange()},
    receivers = #{} :: #{receiver() => {coap_message:token(), trid(), observe_seq()}},
	nextmid = undefined :: coap_message:msg_id(),
	rescnt = 0 :: non_neg_integer(),
    timer = undefined :: endpoint_timer:timer_state(),
    sock = undefined :: inet:socket(),
    transport = undefined :: module(),
    ep_id = undefined :: ecoap_endpoint_id(),
    handler_sup = undefined :: undefined | pid(),
    handler_regs = #{} :: #{ecoap_handler:handler_id() => pid()},
    handler_refs = #{} :: #{reference() => ecoap_handler:handler_id()},
    client_set = ordsets:new() :: ordsets:set(pid())
}).

-type endpoint_addr() :: {inet:ip_address(), inet:port_number()}.
-type ecoap_endpoint_id() :: {ecoap_socket:socket_id(), endpoint_addr()}.
-type trid() :: {in | out, coap_message:msg_id()}.
-type receiver() :: {pid(), reference()}.
-type observe_seq() :: non_neg_integer().

-opaque state() :: #state{}.

-export_type([state/0]).
-export_type([trid/0]).
-export_type([receiver/0]).
-export_type([endpoint_addr/0]).
-export_type([ecoap_endpoint_id/0]).

%% API.

-spec start_link(module(), inet:socket(), ecoap_endpoint_id(), ecoap_config:protocol_config()) -> {ok, pid()} | {error, term()}.
start_link(Transport, Socket, EpID, ProtoConfig) ->
    start_link(undefined, Transport, Socket, EpID, ProtoConfig).
    
% -spec start_link(pid() | undefined, module(), inet:socket(), ecoap_endpoint_id(), ecoap_config:protocol_config()) -> {ok, pid()} | {error, term()}.
start_link(SupPid, Transport, Socket, EpID, Name) ->
    gen_server:start_link(?MODULE, [SupPid, Transport, Socket, EpID, Name], []).

-spec ping(pid()) -> {ok, reference()}.
ping(EndpointPid) ->
    ping(EndpointPid, make_ref()).

-spec ping(pid(), Ref) -> {ok, Ref}.
ping(EndpointPid, Ref) ->
    send_message(EndpointPid, Ref, {ping, ecoap_request:ping_msg()}).

-spec send(pid(), coap_message:coap_message()) -> {ok, reference()}.
send(EndpointPid, Message) ->
    send(EndpointPid, coap_message:get_type(Message), coap_message:get_code(Message), Message).

send(EndpointPid, Type, Code, Message) when is_tuple(Code); Type=='ACK'; Type=='RST' ->
    send_response(EndpointPid, make_ref(), Message);
send(EndpointPid, _Type, _Code, Message) ->
    send_request(EndpointPid, make_ref(), Message).

% -spec send_request(pid(), Ref, coap_message:coap_message()) -> {ok, Ref}.
% send_request(EndpointPid, Ref, Message=#coap_message{token= <<>>}) ->
%     % when no token is assigned then generate one
%     gen_server:cast(EndpointPid, {send_request, Message#coap_message{token=ecoap_message_token:generate_token()}, {self(), Ref}}),
%     {ok, Ref};
% send_request(EndpointPid, Ref, Message) ->
%     % use user defined token
%     gen_server:cast(EndpointPid, {send_request, Message, {self(), Ref}}),
%     {ok, Ref}.

-spec send_request(pid(), Ref, coap_message:coap_message()) -> {ok, Ref}.
send_request(EndpointPid, Ref, Message) ->
    gen_server:cast(EndpointPid, {send_request, Message, {self(), Ref}}),
    {ok, Ref}.

-spec send_message(pid(), Ref, {ping | message, coap_message:coap_message()}) -> {ok, Ref}.
send_message(EndpointPid, Ref, {Tag, Message}) ->
    gen_server:cast(EndpointPid, {send_message, {Tag, Message}, {self(), Ref}}),
    {ok, Ref}.

-spec send_response(pid(), Ref, coap_message:coap_message()) -> {ok, Ref}.
send_response(EndpointPid, Ref, Message) ->
    gen_server:cast(EndpointPid, {send_response, Message, {self(), Ref}}),
    {ok, Ref}.

-spec cancel_request(pid(), reference()) -> ok.
cancel_request(EndpointPid, Ref) ->
    gen_server:cast(EndpointPid, {cancel_request, {self(), Ref}}).

% monitor_handler(EndpointPid, Pid) ->
%     EndpointPid ! {handler_started, Pid}, ok.

-spec register_handler(pid(), ecoap_handler:handler_id(), pid()) -> ok.
register_handler(EndpointPid, ID, Pid) ->
    EndpointPid ! {register_handler, ID, Pid}, ok.

-spec get_peer_info(transport, ecoap_endpoint_id()) -> atom();
                   (ip, ecoap_endpoint_id()) -> inet:ip_address();
                   (port, ecoap_endpoint_id()) -> inet:port_number().
get_peer_info(transport, {RawTransport, _}) -> RawTransport;
get_peer_info(ip, {_, {PeerIP, _}}) -> PeerIP;
get_peer_info(port, {_, {_, PeerPortNo}}) -> PeerPortNo.

% request_complete(EndpointPid, Receiver, ResponseType) ->
%     EndpointPid ! {request_complete, Receiver, ResponseType}, ok. 

%% gen_server.

% client
init([undefined, Transport, Socket, EpID, ProtoConfig0]) ->
    % we would like to terminate as well when upper layer socket process terminates
    process_flag(trap_exit, true),
    ProtoConfig = ecoap_config:merge_protocol_config(ProtoConfig0#{endpoint_pid=>self()}),
    Timer = endpoint_timer:start_timer(?SCAN_INTERVAL, start_scan),
    {ok, #state{transport=Transport, sock=Socket, ep_id=EpID, nextmid=ecoap_message_id:first_mid(), timer=Timer, protocol_config=ProtoConfig}};
% server
init([SupPid, Transport, Socket, EpID, Name]) ->
    % need this also in server mode to avoid termination with ecoap_client 
    process_flag(trap_exit, true),
    ProtoConfig0 = ecoap_registry:get_protocol_config(Name),
    ProtoConfig = ecoap_config:merge_protocol_config(ProtoConfig0#{endpoint_pid=>self()}),
    Timer = endpoint_timer:start_timer(?SCAN_INTERVAL, start_scan),
    {ok, #state{transport=Transport, sock=Socket, ep_id=EpID, nextmid=ecoap_message_id:first_mid(), timer=Timer, protocol_config=ProtoConfig}, {continue, {init, SupPid}}}.

handle_continue({init, SupPid}, State) ->
    {ok, HdlSupPid} = endpoint_sup:start_handler_sup(SupPid),
    {noreply, State#state{handler_sup=HdlSupPid}}.

handle_call(_Request, _From, State) ->
    logger:log(error, "unexpected call ~p received by ~p as ~p~n", [_Request, self(), ?MODULE]),
	{noreply, State}.

% outgoing CON(0) or NON(1) request
handle_cast({send_request, Message, Receiver}, State) ->
    make_new_request(Message, Receiver, State);
% outgoing CON(0) or NON(1)
handle_cast({send_message, Message, Receiver}, State) ->
    make_new_message(Message, Receiver, State);
% outgoing response, either CON(0) or NON(1), piggybacked ACK(2) or RST(3)
handle_cast({send_response, Message, Receiver}, State) ->
    make_new_response(Message, Receiver, State);
% cancel request include removing token, request exchange state and receiver reference
handle_cast({cancel_request, Receiver}, State=#state{receivers=Receivers}) ->
    case maps:find(Receiver, Receivers) of
        {ok, {Token, TrId, _}} ->
            {noreply, do_cancel_msg(TrId, complete_request(Receiver, Token, State))};
        error ->
            {noreply, State}
    end;
handle_cast(_Msg, State) ->
    logger:log(error, "unexpected cast ~p received by ~p as ~p~n", [_Msg, self(), ?MODULE]),
	{noreply, State}.

%% CoAP Message Format
%%
%%  0                   1                   2                   3
%%  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
%% +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%% |Ver| T |  TKL  |      Code     |          Message ID           |
%% +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%% |   Token (if any, TKL bytes) ...                               |
%% +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%% |   Options (if any) ...                                        |
%% +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%% |1 1 1 1 1 1 1 1|    Payload (if any) ...                       |
%% +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%%
%%
% incoming CON(0) or NON(1) request
% pure client would reply with reset
handle_info({datagram, <<?VERSION:2, 0:1, _:1, _TKL:4, 0:3, _CodeDetail:5, MsgId:16, _/bytes>>},
    State=#state{handler_sup=undefined, sock=Socket, transport=Transport, ep_id=EpID}) ->
    logger:log(info, "unexpected request received by ~p as ~p used as client, sending RST~n", [self(), ?MODULE]),
    BinRST = coap_message:encode(ecoap_request:rst(MsgId)),
    Transport:send(Socket, EpID, BinRST),
    {noreply, State};
% incoming CON(0) or NON(1) request
% server/client sharing socket with server would handle it
handle_info({datagram, BinMessage = <<?VERSION:2, 0:1, _:1, _TKL:4, 0:3, _CodeDetail:5, MsgId:16, _/bytes>>}, 
    State=#state{protocol_config=ProtoConfig}) ->
	TrId = {in, MsgId},
    update_state(State, TrId,
        ecoap_exchange:received(BinMessage, ProtoConfig, create_exchange(TrId, undefined, State)));
% incoming CON(0) or NON(1) response
handle_info({datagram, BinMessage = <<?VERSION:2, 0:1, _:1, TKL:4, _Code:8, MsgId:16, Token:TKL/bytes, _/bytes>>},
    State=#state{trans=Trans, tokens=Tokens, sock=Socket, transport=Transport, ep_id=EpID, protocol_config=ProtoConfig}) ->
	TrId = {in, MsgId},
    case maps:find(TrId, Trans) of
        % this is a duplicate msg, i.e. a retransmitted CON response
        {ok, TrState} ->
            update_state(State, TrId, ecoap_exchange:received(BinMessage, ProtoConfig, TrState));
        % this is a new msg
        error ->
             case maps:find(Token, Tokens) of
                {ok, Receiver} ->
                    update_state(State, TrId,
                        ecoap_exchange:received(BinMessage, ProtoConfig, init_exchange(TrId, Receiver)));
                error ->
                    % token was not recognized
                    logger:log(debug, "separate response with unrecognized token received by ~p as ~p, sending RST~n", [self(), ?MODULE]),
                    BinRST = coap_message:encode(ecoap_request:rst(MsgId)),
                    Transport:send(Socket, EpID, BinRST),
                    {noreply, State}
            end
    end;
% incoming empty ACK(2) or RST(3) to an outgoing request or response
handle_info({datagram, BinMessage = <<?VERSION:2, _:2, 0:4, _Code:8, MsgId:16>>}, 
    State=#state{trans=Trans, protocol_config=ProtoConfig}) ->
    TrId = {out, MsgId},
    case maps:find(TrId, Trans) of
        {ok, TrState} -> update_state(State, TrId, ecoap_exchange:received(BinMessage, ProtoConfig, TrState));
        error -> {noreply, State}
    end;
% incoming ACK(2) to an outgoing request
handle_info({datagram, BinMessage = <<?VERSION:2, 2:2, TKL:4, _Code:8, MsgId:16, Token:TKL/bytes, _/bytes>>},
    State=#state{trans=Trans, tokens=Tokens, protocol_config=ProtoConfig}) ->
    TrId = {out, MsgId},
    case maps:find(TrId, Trans) of
        {ok, TrState} ->
            case maps:is_key(Token, Tokens) of
                true ->
                    update_state(State, TrId, ecoap_exchange:received(BinMessage, ProtoConfig, TrState));
                false ->
                    % logger:log(info, "ACK response with unrecognized token received by ~p as ~p~n", [self(), ?MODULE]),
                    {noreply, State}
            end;
        error ->
            % ignore unexpected responses;
            {noreply, State}
    end;
% silently ignore other versions
handle_info({datagram, <<Ver:2, _/bytes>>}, State) when Ver /= ?VERSION ->
    {noreply, State};

handle_info(start_scan, State) ->
    scan_state(State);

handle_info({timeout, TrId, Event}, State=#state{trans=Trans, protocol_config=ProtoConfig}) ->
    case maps:find(TrId, Trans) of
        {ok, TrState} -> update_state(State, TrId, ecoap_exchange:timeout(Event, ProtoConfig, TrState));
        error -> {noreply, State} % ignore unexpected responses
    end;

% handle_info({request_complete, Receiver, ResObserve}, State=#state{receivers=Receivers}) ->
%     %io:format("request_complete~n"),
%     case maps:find(Receiver, Receivers) of
%         {ok, {Token, _, ReqObserve}} ->
%             {noreply, maybe_complete_request(ReqObserve, ResObserve, Receiver, Token, State)};
%         error ->
%             {noreply, State}
%     end;
 
% handle_info({handler_started, Pid}, State=#state{rescnt=Count, handler_refs=Refs}) ->
%     erlang:monitor(process, Pid),
%     {noreply, State#state{rescnt=Count+1, handler_refs=maps:put(Pid, undefined, Refs)}};

% Only record pid of possible observe/blockwise handlers instead of every new spawned handler
% so that we have better parallelism
handle_info({register_handler, ID, Pid}, State=#state{handler_regs=Regs}) ->
    case maps:find(ID, Regs) of
        {ok, Pid} -> 
            % handler already registered
            {noreply, State};
        {ok, Pid2} ->  
            % only one handler for each operation allowed, so we terminate the one started earlier
            ok = ecoap_handler:close(Pid2),
            {noreply, State};
        error ->
            Regs2 = update_handler_regs(ID, Pid, Regs),
            {noreply, State#state{handler_regs=Regs2}}
    end;

handle_info({'DOWN', Ref, process, _Pid, _Reason}, State=#state{rescnt=Count, handler_regs=Regs, handler_refs=Refs}) ->
    case maps:find(Ref, Refs) of
        {ok, ID} -> 
            Regs2 = purge_handler_regs(ID, Regs),
            {noreply, State#state{rescnt=Count-1, handler_regs=Regs2, handler_refs=maps:remove(Ref, Refs)}};
        error -> 
            {noreply, State}
    end;

handle_info({'EXIT', Pid, _Reason}, State=#state{receivers=Receivers, client_set=CSet}) ->
    % if this exit signal comes from an embedded client which shares the same socket process with the server
    % we should ensure all requests the client issued that have not been completed yet are cancelled
    case is_client(Pid, CSet) of
        true ->
            CSet2 = purge_client_set(Pid, CSet),
            State2 = maps:fold(fun(Receiver={ClientPid, _}, {Token, TrId, _}, Acc) when ClientPid =:= Pid -> 
                                do_cancel_msg(TrId, complete_request(Receiver, Token, Acc));
                                (_, _, Acc) -> Acc end, State#state{client_set=CSet2}, Receivers),
            {noreply, State2};
        false ->
            {noreply, State}
    end;
    
handle_info(_Info, State) ->
    logger:log(error, "unexpected info ~p received by ~p as ~p~n", [_Info, self(), ?MODULE]),
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%% Internal

%% TODO: 
% RFC 7252 4.7
% In order not to cause congestion, clients (including proxies) MUST
% strictly limit the number of simultaneous outstanding interactions
% that they maintain to a given server (including proxies) to NSTART.
% An outstanding interaction is either a CON for which an ACK has not
% yet been received but is still expected (message layer) or a request
% for which neither a response nor an Acknowledgment message has yet
% been received but is still expected (which may both occur at the same
% time, counting as one outstanding interaction).  The default value of
% NSTART for this specification is 1.

% The specific algorithm by which a client stops to "expect" a response
% to a Confirmable request that was acknowledged, or to a Non-
% confirmable request, is not defined.  Unless this is modified by
% additional congestion control optimizations, it MUST be chosen in
% such a way that an endpoint does not exceed an average data rate of
% PROBING_RATE in sending to another endpoint that does not respond.

% a server SHOULD implement some rate limiting for its
% response transmission based on reasonable assumptions about
% application requirements.

% We may need to add a queue for outgoing confirmable msg so that it does not violate NSTART=1
% and a queue for outgoing non-confirmable msg so that we can keep a counter and 
% change a msg from NON to CON periodically & limit data rate according to some congestion control strategy (e.g. cocoa)
% problem: What should we do when queue overflows? Should we inform the req/resp sender?

make_new_request(Message, Receiver, State=#state{receivers=Receivers, protocol_config=#{token_length:=TKL}}) ->
    Token = case maps:find(Receiver, Receivers) of
        {ok, {OldToken, _, _}} -> OldToken;
        error -> ecoap_message_token:generate_token(TKL)
    end,
    go_make_new_request(Message, Token, Receiver, State).

go_make_new_request(Message, Token, Receiver={ClientPid, _}, State=#state{nextmid=MsgId, tokens=Tokens, receivers=Receivers, client_set=CSet}) ->
    Tokens2 = maps:put(Token, Receiver, Tokens),
    Receivers2 = maps:put(Receiver, {Token, {out, MsgId}, coap_message:get_option('Observe', Message)}, Receivers),
    CSet2 = update_client_set(ClientPid, CSet),
    make_new_message({message, coap_message:set_token(Token, Message)}, Receiver, State#state{tokens=Tokens2, receivers=Receivers2, client_set=CSet2}).

make_new_message({ping, Message}, Receiver, State) ->
    go_make_new_request(Message, <<>>, Receiver, State);
make_new_message({message, Message}, Receiver, State=#state{nextmid=MsgId}) ->
    make_message({out, MsgId}, coap_message:set_id(MsgId, Message), Receiver, State#state{nextmid=ecoap_message_id:next_mid(MsgId)}).

make_message(TrId, Message, Receiver, State=#state{protocol_config=ProtoConfig}) ->
    update_state(State, TrId,
        ecoap_exchange:send(Message, ProtoConfig, init_exchange(TrId, Receiver))).

%% TODO: decide whether to send a CON notification considering other notifications may be in transit
%%       and how to keep the retransimit counter for a newer notification when the former one timed out
make_new_response(Message, Receiver, State=#state{trans=Trans, protocol_config=ProtoConfig}) ->
    % io:format("The response: ~p~n", [Message]),
    TrId = {in, coap_message:get_id(Message)},
    case maps:find(TrId, Trans) of
        {ok, TrState} ->
            % coap_transport:awaits_response is used to 
            % check if we are in the case that
            % we received a CON request, have its state stored, but did not send its ACK yet
            case ecoap_exchange:awaits_response(TrState) of
                true ->
                    % request is found in store and is in awaits_response state
                    % we are about to send ACK by calling coap_exchange:send, we make the state change to pack_sent
                    update_state(State, TrId,
                        ecoap_exchange:send(Message, ProtoConfig, TrState));
                false ->
                    % request is found in store but not in awaits_response state
                    % which means we are in one of the three following cases
                    % 1. we are going to send a NON response whose original NON request has not expired yet
                    % 2. ... send a separate response whose original request has been empty acked and not expired yet
                    % 3. ... send an observe notification whose original request has been responded and not expired yet
                    make_new_message({message, Message}, Receiver, State)
            end;
        error ->
            % no TrState is found, which implies the original request has expired
            % 1. we are going to send a NON response whose original NON request has expired
            % 2. ... send a separate response whose original request has been empty acked and expired
            % 3. ... send an observe notification whose original request has been responded and expired
            make_new_message({message, Message}, Receiver, State)
    end.

% find or initialize a new exchange
create_exchange(TrId, Receiver, #state{trans=Trans}) ->
    maps:get(TrId, Trans, init_exchange(TrId, Receiver)).

init_exchange(TrId, Receiver) ->
    ecoap_exchange:init(TrId, Receiver).

scan_state(State=#state{protocol_config=#{exchange_lifetime:=0, non_lifetime:=0}}) ->
    purge_state(State);
scan_state(State=#state{trans=Trans}) ->
    CurrentTime = erlang:monotonic_time(),
    Trans2 = maps:filter(fun(_TrId, TrState) -> ecoap_exchange:not_expired(CurrentTime, TrState) end, Trans),
    purge_state(State#state{trans=Trans2}).

update_client_set(ClientPid, CSet) ->
    ordsets:add_element(ClientPid, CSet).

purge_client_set(ClientPid, CSet) ->
    ordsets:del_element(ClientPid, CSet).

is_client(ClientPid, CSet) ->
    ordsets:is_element(ClientPid, CSet).

client_set_size(CSet) ->
    ordsets:size(CSet).

% This is the code for issue where one client send mulitiple observer requests to same resource with different tokens
% update_handler_regs({_, undefined}=ID, Pid, Regs) ->
%     Regs#{ID=>Pid};
% update_handler_regs({RID, _}=ID, Pid, Regs) ->
%     Regs#{ID=>Pid, {RID, undefined}=>Pid}.

% purge_handler_regs({_, undefined}=ID, Regs) ->
%     maps:remove(ID, Regs);
% purge_handler_regs({RID, _}=ID, Regs) ->
%     maps:remove(ID, maps:remove({RID, undefined}, Regs)).

update_handler_regs(ID, Pid, Regs) ->
    maps:put(ID, Pid, Regs).

purge_handler_regs(ID, Regs) ->
    maps:remove(ID, Regs).

update_state(State=#state{trans=Trans, timer=Timer}, TrId, {Actions, Exchange}) ->
    {Exchange2, State2} = execute(Actions, Exchange, State),
    {noreply, State2#state{trans=update_trans(TrId, Exchange2, Trans), timer=endpoint_timer:kick_timer(Timer)}}.

update_trans(TrId, undefined, Trans) ->
    maps:remove(TrId, Trans);
update_trans(TrId, Exchange, Trans) ->
    maps:put(TrId, Exchange, Trans).


execute([], Exchange, State) ->
    {ecoap_exchange:check_next_state(Exchange), State};

execute([{start_timer, TimeOut}|Rest], Exchange, State) ->
    Timer = ecoap_exchange:timeout_after(TimeOut, self(), Exchange),
    execute(Rest, ecoap_exchange:set_timer(Timer, Exchange), State);

execute([cancel_timer|Rest], Exchange, State) ->
    _ = ecoap_exchange:cancel_timer(Exchange),
    execute(Rest, ecoap_exchange:set_timer(undefined, Exchange), State);

execute([{handle_request, Message}|Rest], Exchange, State) ->
    State2 = handle_request(Message, State),
    execute(Rest, Exchange, State2);

execute([{handle_response, Message}|Rest], Exchange, State) ->
    State2 = handle_response(Message, Exchange, State),
    execute(Rest, Exchange, State2);

execute([{handle_error, Message, Reason}|Rest], Exchange, State) ->
    State2 = handle_error(Message, Reason, Exchange, State),
    execute(Rest, Exchange, State2);

execute([{handle_ack, Message}|Rest], Exchange, State) ->
    ok = handle_ack(Message, Exchange, State),
    execute(Rest, Exchange, State);

execute([{send, BinMessage}|Rest], Exchange, State=#state{sock=Socket, transport=Transport, ep_id=EpID}) ->
    Transport:send(Socket, EpID, BinMessage),
    execute(Rest, Exchange, State).


handle_request(Message, State=#state{ep_id=EpID, protocol_config=ProtoConfig, handler_sup=HdlSupPid}) ->
    %io:fwrite("handle_request called from ~p with ~p~n", [self(), Message]),
    HandlerID = ecoap_handler:handler_id(Message),
    HandlerConfig = ecoap_config:handler_config(ProtoConfig),
    case get_handler(HdlSupPid, HandlerID, HandlerConfig, State) of
        {ok, Pid, State2} ->
            Pid ! {coap_request, EpID, self(), undefined, Message},
            State2;
        {error, _Error} ->
            {ok, _} = ecoap_endpoint:send(self(),
                ecoap_request:response({error, 'InternalServerError'}, Message)),
            State
    end.

handle_response(Message, Exchange, State=#state{ep_id=EpID}) ->
    % logger:log(debug, "handle_response called from ~p with ~p~n", [self(), Message]),    
    {Sender, Ref} = Receiver = ecoap_exchange:get_receiver(Exchange),
    Sender ! {coap_response, EpID, self(), Ref, Message},
    request_complete(Message, Receiver, State).

handle_error(Message, Error, Exchange, State=#state{ep_id=EpID}) ->
    % logger:log(debug, "handle_error called from ~p with ~p~n", [self(), Message]),
    {Sender, Ref} = Receiver = ecoap_exchange:get_receiver(Exchange),
    Sender ! {coap_error, EpID, self(), Ref, Error},
    request_complete(Message, Receiver, State).

handle_ack(_Message, Exchange, #state{ep_id=EpID}) ->
    % logger:log(debug, "handle_ack called from ~p with ~p~n", [self(), _Message]),
    {Sender, Ref} = ecoap_exchange:get_receiver(Exchange),
    Sender ! {coap_ack, EpID, self(), Ref},
    ok.

request_complete(Message, Receiver, State=#state{receivers=Receivers}) ->
    case maps:find(Receiver, Receivers) of
        {ok, {Token, _, ReqObserve}} ->
            maybe_complete_request(ReqObserve, coap_message:get_option('Observe', Message), Receiver, Token, State);
        error ->
            State
    end.

get_handler(SupPid, ID, HandlerConfig, State=#state{rescnt=Count, handler_regs=Regs, handler_refs=Refs}) ->
    case maps:find(ID, Regs) of
        {ok, Pid} ->
            {ok, Pid, State};
        error ->          
            case ecoap_handler_sup:start_handler(SupPid, [ID, HandlerConfig]) of
                {ok, Pid} ->
                    Ref = erlang:monitor(process, Pid),
                    {ok, Pid, State#state{rescnt=Count+1, handler_refs=maps:put(Ref, ID, Refs)}};
                Else ->
                    Else    
            end
    end.

maybe_complete_request(ReqObserve, ResObserve, _, _, State) when is_integer(ReqObserve), is_integer(ResObserve) ->
    State;
maybe_complete_request(_, _, Receiver, Token, State) ->
    complete_request(Receiver, Token, State).

complete_request(Receiver, Token, State=#state{receivers=Receivers, tokens=Tokens}) ->
    State#state{receivers=maps:remove(Receiver, Receivers), tokens=maps:remove(Token, Tokens)}.

do_cancel_msg(TrId, State=#state{trans=Trans}) ->
    case maps:find(TrId, Trans) of 
        {ok, TrState} -> 
            State#state{trans=maps:update(TrId, ecoap_exchange:cancel_msg(TrState), Trans)}; 
        error -> 
            State 
    end.

% update_state(State=#state{trans=Trans, timer=Timer}, TrId, undefined) ->
%     Trans2 = maps:remove(TrId, Trans),
%     {noreply, State#state{trans=Trans2, timer=endpoint_timer:kick_timer(Timer)}};
% update_state(State=#state{trans=Trans, timer=Timer}, TrId, TrState) ->
%     Trans2 = maps:put(TrId, TrState, Trans),
%     {noreply, State#state{trans=Trans2, timer=endpoint_timer:kick_timer(Timer)}}.
purge_state(State=#state{tokens=Tokens, trans=Trans, rescnt=Count, client_set=CSet, timer=Timer}) ->
    case {maps:size(Tokens) + maps:size(Trans) + Count + client_set_size(CSet), endpoint_timer:is_kicked(Timer)} of
        {0, false} -> 
            {stop, normal, State};
        _ -> 
            Timer2 = endpoint_timer:restart_timer(Timer),
            {noreply, State#state{timer=Timer2}}
    end.
