-module(ecoap_endpoint).
-behaviour(gen_server).

%% API.
-export([start_link/4, start_link/3,
        ping/1, send/2, send_message/3, send_request/3, send_response/3, cancel_request/2]).
-export([monitor_handler/2, register_handler/3]).
-export([check_alive/1]).

%% gen_server.
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-define(VERSION, 1).

-define(SCAN_INTERVAL, 10000). % scan every 10s

-record(state, {
    trans_args = undefined :: trans_args(),
	tokens = #{} :: #{binary() => receiver()},
	trans = #{} :: #{trid() => ecoap_exchange:exchange()},
    receivers = #{} :: #{receiver() => {binary(), trid()}},
	nextmid = undefined :: coap_message:msg_id(),
	rescnt = 0 :: non_neg_integer(),
    handler_refs = #{} ::  #{pid() => tuple() | undefined},
    timer = undefined :: endpoint_timer:timer_state()
}).

-type trid() :: {in | out, coap_message:msg_id()}.
-type receiver() :: {pid(), reference()}.
-type trans_args() :: #{sock := inet:socket(),
                        sock_module := module(), 
                        ep_id := ecoap_udp_socket:ecoap_endpoint_id(), 
                        endpoint_pid := pid(), 
                        handler_sup => pid(),
                        handler_regs => #{tuple() => pid()}}.

-opaque state() :: #state{}.

-export_type([state/0]).
-export_type([trid/0]).
-export_type([receiver/0]).
-export_type([trans_args/0]).

-include("ecoap.hrl").
-include("coap_message.hrl").

%% API.
-spec start_link(pid(), module(), inet:socket(), ecoap_udp_socket:ecoap_endpoint_id()) -> {ok, pid()}.
start_link(SupPid, SocketModule, Socket, EpID) ->
	proc_lib:start_link(?MODULE, init, [[SupPid, SocketModule, Socket, EpID]]).

-spec start_link(module(), inet:socket(), ecoap_udp_socket:ecoap_endpoint_id()) -> {ok, pid()}.
start_link(SocketModule, Socket, EpID) ->
    gen_server:start_link(?MODULE, [undefined, SocketModule, Socket, EpID], []).

-spec ping(pid()) -> {ok, reference()}.
ping(EndpointPid) ->
    send_message(EndpointPid, make_ref(), #coap_message{type='CON', id=0}).

-spec send(pid(), coap_message:coap_message()) -> {ok, reference()}.
send(EndpointPid, Message=#coap_message{type=Type, code=Code}) when is_tuple(Code); Type=='ACK'; Type=='RST' ->
    send_response(EndpointPid, make_ref(), Message);
send(EndpointPid, Message=#coap_message{}) ->
    send_request(EndpointPid, make_ref(), Message).

-spec send_request(pid(), Ref, coap_message:coap_message()) -> {ok, Ref}.
% send_request(EndpointPid, Ref, Message=#coap_message{token= <<>>}) ->
%     % when no token is assigned then generate one
%     gen_server:cast(EndpointPid, {send_request, Message#coap_message{token=ecoap_message_token:generate_token()}, {self(), Ref}}),
%     {ok, Ref};
% send_request(EndpointPid, Ref, Message) ->
%     % use user defined token
%     gen_server:cast(EndpointPid, {send_request, Message, {self(), Ref}}),
%     {ok, Ref}.

send_request(EndpointPid, Ref, Message) ->
    % use user defined token
    gen_server:cast(EndpointPid, {send_request, Message, {self(), Ref}}),
    {ok, Ref}.

-spec send_message(pid(), Ref, coap_message:coap_message()) -> {ok, Ref}.
send_message(EndpointPid, Ref, Message) ->
    gen_server:cast(EndpointPid, {send_message, Message, {self(), Ref}}),
    {ok, Ref}.

-spec send_response(pid(), Ref, coap_message:coap_message()) -> {ok, Ref}.
send_response(EndpointPid, Ref, Message) ->
    gen_server:cast(EndpointPid, {send_response, Message, {self(), Ref}}),
    {ok, Ref}.

-spec cancel_request(pid(), reference()) -> ok.
cancel_request(EndpointPid, Ref) ->
    gen_server:cast(EndpointPid, {cancel_request, {self(), Ref}}).

monitor_handler(EndpointPid, Pid) ->
    EndpointPid ! {handler_started, Pid}, ok.

register_handler(EndpointPid, ID, Pid) ->
    EndpointPid ! {register_handler, ID, Pid}, ok.

% used by client to ensure aliveness of an ecoap_endpoint process
check_alive(EndpointPid) ->
    gen_server:call(EndpointPid, check_alive).

%% gen_server.

% client
init([undefined, SocketModule, Socket, EpID]) ->
    % we would like to terminate as well when upper layer socket process terminates
    process_flag(trap_exit, true),
    TransArgs = #{sock=>Socket, sock_module=>SocketModule, ep_id=>EpID, endpoint_pid=>self()},
    Timer = endpoint_timer:start_timer(?SCAN_INTERVAL, start_scan),
    {ok, #state{nextmid=ecoap_message_id:first_mid(), timer=Timer, trans_args=TransArgs}};

% server 
init([SupPid, SocketModule, Socket, EpID]) ->
    ok = proc_lib:init_ack({ok, self()}),
    process_flag(trap_exit, true),
    {ok, HdlSupPid} = supervisor:start_child(SupPid, 
        #{id => ecoap_handler_sup,
          start => {ecoap_handler_sup, start_link, []},
          restart => permanent, 
          shutdown => infinity, 
          type => supervisor, 
          modules => [ecoap_handler_sup]}),
    TransArgs = #{sock=>Socket, sock_module=>SocketModule, ep_id=>EpID, endpoint_pid=>self(), handler_sup=>HdlSupPid, handler_regs=>#{}},
    Timer = endpoint_timer:start_timer(?SCAN_INTERVAL, start_scan),
    gen_server:enter_loop(?MODULE, [], #state{nextmid=ecoap_message_id:first_mid(), timer=Timer, trans_args=TransArgs}).

handle_call(check_alive, _From, State=#state{timer=Timer}) ->
    {reply, ok, State#state{timer=endpoint_timer:kick_timer(Timer)}};
handle_call(_Request, _From, State) ->
    error_logger:error_msg("unexpected call ~p received by ~p as ~p~n", [_Request, self(), ?MODULE]),
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
handle_cast({cancel_request, Receiver}, State=#state{tokens=Tokens, trans=Trans, receivers=Receivers}) ->
    case maps:find(Receiver, Receivers) of
        {ok, {Token, TrId}} ->
            Tokens2 = maps:remove(Token, Tokens),
            Receivers2 = maps:remove(Receiver, Receivers),
            Trans2 = case maps:find(TrId, Trans) of
                {ok, TrState} -> maps:update(TrId, ecoap_exchange:cancel_msg(TrState), Trans);
                error -> Trans
            end,
            {noreply, State#state{tokens=Tokens2, trans=Trans2, receivers=Receivers2}};
        error ->
            {noreply, State}
    end;
handle_cast(_Msg, State) ->
    error_logger:error_msg("unexpected cast ~p received by ~p as ~p~n", [_Msg, self(), ?MODULE]),
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
handle_info({datagram, BinMessage = <<?VERSION:2, 0:1, _:1, _TKL:4, 0:3, _CodeDetail:5, MsgId:16, _/bytes>>}, 
    State=#state{trans_args=TransArgs}) ->
	TrId = {in, MsgId},
    update_state(State, TrId,
        ecoap_exchange:received(BinMessage, TransArgs, create_exchange(TrId, undefined, State)));
% incoming CON(0) or NON(1) response
handle_info({datagram, BinMessage = <<?VERSION:2, 0:1, _:1, TKL:4, _Code:8, MsgId:16, Token:TKL/bytes, _/bytes>>},
    State=#state{trans=Trans, tokens=Tokens, trans_args=TransArgs=#{sock:=Socket, sock_module:=SocketModule, ep_id:=EpID}}) ->
	TrId = {in, MsgId},
    case maps:find(TrId, Trans) of
        % this is a duplicate msg, i.e. a retransmitted CON response
        {ok, TrState} ->
            update_state(State, TrId, ecoap_exchange:received(BinMessage, TransArgs, TrState));
        % this is a new msg
        error ->
             case maps:find(Token, Tokens) of
                {ok, Receiver} ->
                    update_state(State, TrId,
                        ecoap_exchange:received(BinMessage, TransArgs, init_exchange(TrId, Receiver)));
                error ->
                    % token was not recognized
                    BinRST = coap_message:encode(ecoap_request:rst(MsgId)),
                    %io:fwrite("<- reset~n"),
                    ok = SocketModule:send_datagram(Socket, EpID, BinRST),
                    {noreply, State}
            end
    end;
% incoming empty ACK(2) or RST(3) to an outgoing request or response
handle_info({datagram, BinMessage = <<?VERSION:2, _:2, 0:4, _Code:8, MsgId:16>>}, 
    State=#state{trans=Trans, trans_args=TransArgs}) ->
    TrId = {out, MsgId},
    case maps:find(TrId, Trans) of
        {ok, TrState} -> update_state(State, TrId, ecoap_exchange:received(BinMessage, TransArgs, TrState));
        error -> {noreply, State}
    end;
% incoming ACK(2) to an outgoing request
handle_info({datagram, BinMessage = <<?VERSION:2, 2:2, TKL:4, _Code:8, MsgId:16, Token:TKL/bytes, _/bytes>>},
    State=#state{trans=Trans, tokens=Tokens, trans_args=TransArgs}) ->
    TrId = {out, MsgId},
    case maps:find(TrId, Trans) of
        {ok, TrState} ->
            case maps:is_key(Token, Tokens) of
                true ->
                    update_state(State, TrId, ecoap_exchange:received(BinMessage, TransArgs, TrState));
                false ->
                    % io:fwrite("unrecognized token~n"),
                    {noreply, State}
            end;
        error ->
            % ignore unexpected responses;
            {noreply, State}
    end;
% silently ignore other versions
handle_info({datagram, <<Ver:2, _/bytes>>}, State) when Ver /= ?VERSION ->
    % %io:format("unknown CoAP version~n"),
    {noreply, State};

handle_info(start_scan, State) ->
    scan_state(State);

handle_info({timeout, TrId, Event}, State=#state{trans=Trans, trans_args=TransArgs}) ->
    case maps:find(TrId, Trans) of
        {ok, TrState} -> update_state(State, TrId, ecoap_exchange:timeout(Event, TransArgs, TrState));
        error -> {noreply, State} % ignore unexpected responses
    end;

handle_info({request_complete, Receiver}, State=#state{tokens=Tokens, receivers=Receivers}) ->
    %io:format("request_complete~n"),
    {Token, _} = maps:get(Receiver, Receivers, {undefined, undefined}),
    {noreply, State#state{tokens=maps:remove(Token, Tokens), receivers=maps:remove(Receiver, Receivers)}};

handle_info({handler_started, Pid}, State=#state{rescnt=Count, handler_refs=Refs}) ->
    erlang:monitor(process, Pid),
    {noreply, State#state{rescnt=Count+1, handler_refs=maps:put(Pid, undefined, Refs)}};

% Only record pid of possible observe/blockwise handlers instead of every new spawned handler
% so that we have better parallelism
handle_info({register_handler, ID, Pid}, State=#state{trans_args=TransArgs=#{handler_regs:=Regs}, handler_refs=Refs}) ->
    case maps:find(ID, Regs) of
        {ok, Pid} -> 
            % handler already registered
            {noreply, State};
        {ok, _Pid2} ->  
            % only one handler for each operation allowed, so we terminate the one started later
            ok = ecoap_handler:close(Pid),
            {noreply, State};
        error ->
            Regs2 = update_handler_regs(ID, Pid, Regs),
            {noreply, State#state{trans_args=TransArgs#{handler_regs:=Regs2}, handler_refs=maps:update(Pid, ID, Refs)}}
    end;

handle_info({'DOWN', _Ref, process, Pid, _Reason}, State=#state{rescnt=Count, trans_args=TransArgs=#{handler_regs:=Regs}, handler_refs=Refs}) ->
    case maps:find(Pid, Refs) of
        {ok, undefined} ->
            {noreply, State#state{rescnt=Count-1, handler_refs=maps:remove(Pid, Refs)}};
        {ok, ID} -> 
            Regs2 = purge_handler_regs(ID, Regs),
            {noreply, State#state{rescnt=Count-1, trans_args=TransArgs#{handler_regs:=Regs2}, handler_refs=maps:remove(Pid, Refs)}};
        error -> 
            {noreply, State}
    end;

handle_info({'EXIT', Pid, _Reason}, State=#state{receivers=Receivers, tokens=Tokens, trans=Trans}) ->
    % if this exit signal comes from an embedded client which shares the same socket process with the server
    % we should ensure all requests the client issued that have not been completed yet are cancelled
    {Receivers2, Tokens2, Trans2} =  
        maps:fold(fun(Receiver={ClientPid, _}, {Token, TrId}, {AccReceivers, AccTokens, AccTrans}) when ClientPid =:= Pid -> 
                {maps:remove(Receiver, AccReceivers), 
                 maps:remove(Token, AccTokens), 
                 case maps:find(TrId, AccTrans) of 
                    {ok, TrState} -> maps:update(TrId, ecoap_exchange:cancel_msg(TrState), AccTrans); 
                    error -> AccTrans 
                 end};
                (_, _, Acc) -> Acc 
            end, {Receivers, Tokens, Trans}, Receivers),
    {noreply, State#state{tokens=Tokens2, trans=Trans2, receivers=Receivers2}};
    
handle_info(_Info, State) ->
    error_logger:error_msg("unexpected info ~p received by ~p as ~p~n", [_Info, self(), ?MODULE]),
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%% Internal

% TODO: 
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

% make_new_request(Message=#coap_message{token=Token}, Receiver, State=#state{tokens=Tokens, nextmid=MsgId, receivers=Receivers}) ->
%     % in case this is a request using previous token, we need to remove the outdated receiver reference first
%     Receivers2 = maps:put(Receiver, {Token, {out, MsgId}}, maps:remove(maps:get(Token, Tokens, undefined), Receivers)),
%     Tokens2 = maps:put(Token, Receiver, Tokens),
%     make_new_message(Message, Receiver, State#state{tokens=Tokens2, receivers=Receivers2}).

make_new_request(Message, Receiver, State=#state{tokens=Tokens, nextmid=MsgId, receivers=Receivers}) ->
    Token = case maps:find(Receiver, Receivers) of
        {ok, {OldToken, _}} -> OldToken;
        error -> ecoap_message_token:generate_token()
    end,
    Tokens2 = maps:put(Token, Receiver, Tokens),
    Receivers2 = maps:put(Receiver, {Token, {out, MsgId}}, Receivers),
    make_new_message(Message#coap_message{token=Token}, Receiver, State#state{tokens=Tokens2, receivers=Receivers2}).

make_new_message(Message, Receiver, State=#state{nextmid=MsgId}) ->
    make_message({out, MsgId}, Message#coap_message{id=MsgId}, Receiver, State#state{nextmid=ecoap_message_id:next_mid(MsgId)}).

make_message(TrId, Message, Receiver, State=#state{trans_args=TransArgs}) ->
    update_state(State, TrId,
        ecoap_exchange:send(Message, TransArgs, init_exchange(TrId, Receiver))).

% TODO: decide whether to send a CON notification considering other notifications may be in transit
%       and how to keep the retransimit counter for a newer notification when the former one timed out
make_new_response(Message=#coap_message{id=MsgId}, Receiver, State=#state{trans=Trans, trans_args=TransArgs}) ->
    % io:format("The response: ~p~n", [Message]),
    TrId = {in, MsgId},
    case maps:find(TrId, Trans) of
        {ok, TrState} ->
            % io:format("find TrState of ~p~n", [TrId]),
            % coap_transport:awaits_response is used to 
            % check if we are in the case that
            % we received a CON request, have its state stored, but did not send its ACK yet
            case ecoap_exchange:awaits_response(TrState) of
                true ->
                    % io:format("~p is awaits_response~n", [TrId]),
                    % request is found in store and is in awaits_response state
                    % we are about to send ACK by calling coap_exchange:send, we make the state change to pack_sent
                    update_state(State, TrId,
                        ecoap_exchange:send(Message, TransArgs, TrState));
                false ->
                    % io:format("~p is not awaits_response~n", [TrId]),
                    % request is found in store but not in awaits_response state
                    % which means we are in one of the three following cases
                    % 1. we are going to send a NON response whose original NON request has not expired yet
                    % 2. ... send a separate response whose original request has been empty acked and not expired yet
                    % 3. ... send an observe notification whose original request has been responded and not expired yet
                    make_new_message(Message, Receiver, State)
            end;
        error ->
            % io:format("did not find TrState of ~p~n", [TrId]),
            % no TrState is found, which implies the original request has expired
            % 1. we are going to send a NON response whose original NON request has expired
            % 2. ... send a separate response whose original request has been empty acked and expired
            % 3. ... send an observe notification whose original request has been responded and expired
            make_new_message(Message, Receiver, State)
    end.

% find or initialize a new exchange
create_exchange(TrId, Receiver, #state{trans=Trans}) ->
    maps:get(TrId, Trans, init_exchange(TrId, Receiver)).

init_exchange(TrId, Receiver) ->
    ecoap_exchange:init(TrId, Receiver).

-ifdef(NODEDUP).
scan_state(State) ->
    purge_state(State).
-else.
scan_state(State=#state{trans=Trans}) ->
    CurrentTime = erlang:monotonic_time(),
    Trans2 = maps:filter(fun(_TrId, TrState) -> ecoap_exchange:not_expired(CurrentTime, TrState) end, Trans),
    purge_state(State#state{trans=Trans2}).
-endif.

update_handler_regs({_, undefined}=ID, Pid, Regs) ->
    Regs#{ID=>Pid};
update_handler_regs({RID, _}=ID, Pid, Regs) ->
    Regs#{ID=>Pid, {RID, undefined}=>Pid}.

purge_handler_regs({_, undefined}=ID, Regs) ->
    maps:remove(ID, Regs);
purge_handler_regs({RID, _}=ID, Regs) ->
    maps:remove(ID, maps:remove({RID, undefined}, Regs)).

update_state(State=#state{trans=Trans, timer=Timer}, TrId, undefined) ->
    Trans2 = maps:remove(TrId, Trans),
    {noreply, State#state{trans=Trans2, timer=endpoint_timer:kick_timer(Timer)}};
update_state(State=#state{trans=Trans, timer=Timer}, TrId, TrState) ->
    Trans2 = maps:put(TrId, TrState, Trans),
    {noreply, State#state{trans=Trans2, timer=endpoint_timer:kick_timer(Timer)}}.

purge_state(State=#state{tokens=Tokens, trans=Trans, rescnt=Count, timer=Timer}) ->
    case {maps:size(Tokens) + maps:size(Trans) + Count, endpoint_timer:is_kicked(Timer)} of
        {0, false} -> 
            % io:format("All trans expired~n"),
            {stop, normal, State};
        _ -> 
            Timer2 = endpoint_timer:restart_timer(Timer),
            % io:format("Ongoing trans exist~n"),
            {noreply, State#state{timer=Timer2}}
    end.
