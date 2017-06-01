-module(ecoap_endpoint).
-behaviour(gen_server).

%% API.
-export([start_link/4, start_link/3, close/1, 
        ping/1, send/2, send_message/3, send_request/3, send_response/3, cancel_request/2]).
-export([generate_token/0, generate_token/1]).

%% gen_server.
-export([init/1]).
% -export([init/4]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-define(VERSION, 1).
-define(MAX_MESSAGE_ID, 65535). % 16-bit number
-define(SCAN_INTERVAL, 10000). % scan every 10s
-define(TOKEN_LENGTH, 4). % shall be at least 32 random bits

-record(state, {
    trans_args = undefined :: trans_args(),
	tokens = #{} :: #{binary() => receiver()},
	trans = #{} :: #{trid() => ecoap_exchange:exchange()},
    receivers = #{} :: #{receiver() => {binary(), trid()}},
	nextmid = undefined :: msg_id(),
	rescnt = undefined :: non_neg_integer(),
    handler_refs = undefined :: undefined | #{reference() => tuple()},
    timer = undefined :: endpoint_timer:timer_state()
    % mode = server :: server | client
}).

-type trid() :: {in | out, msg_id()}.
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

-include_lib("ecoap_common/include/coap_def.hrl").

% TODO:
% Should we make trid as another field in trans_arg instead of putting trid in each exchange record?

%% API.
-spec start_link(pid(), module(), inet:socket(), ecoap_udp_socket:ecoap_endpoint_id()) -> {ok, pid()}.
start_link(SupPid, SocketModule, Socket, EpID) ->
	proc_lib:start_link(?MODULE, init, [[SupPid, SocketModule, Socket, EpID]]).

-spec start_link(module(), inet:socket(), ecoap_udp_socket:ecoap_endpoint_id()) -> {ok, pid()}.
start_link(SocketModule, Socket, EpID) ->
    gen_server:start_link(?MODULE, [undefined, SocketModule, Socket, EpID], []).

-spec close(pid()) -> ok.
close(Pid) ->
	gen_server:cast(Pid, shutdown).

-spec ping(pid()) -> {ok, reference()}.
ping(EndpointPid) ->
    send_message(EndpointPid, make_ref(), #coap_message{type='CON'}).

-spec send(pid(), coap_message()) -> {ok, reference()}.
send(EndpointPid, Message=#coap_message{type=Type, code=Code}) when is_tuple(Code); Type=='ACK'; Type=='RST' ->
    send_response(EndpointPid, make_ref(), Message);
send(EndpointPid, Message=#coap_message{}) ->
    send_request(EndpointPid, make_ref(), Message).

-spec send_request(pid(), Ref, coap_message()) -> {ok, Ref}.
% when no token is assigned then generate one
send_request(EndpointPid, Ref, Message=#coap_message{token= <<>>}) ->
    Token = generate_token(), 
    gen_server:cast(EndpointPid, {send_request, Message#coap_message{token=Token}, {self(), Ref}}),
    {ok, Ref};
% use user defined token
send_request(EndpointPid, Ref, Message) ->
    gen_server:cast(EndpointPid, {send_request, Message, {self(), Ref}}),
    {ok, Ref}.

-spec send_message(pid(), Ref, coap_message()) -> {ok, Ref}.
send_message(EndpointPid, Ref, Message) ->
    gen_server:cast(EndpointPid, {send_message, Message, {self(), Ref}}),
    {ok, Ref}.

-spec send_response(pid(), Ref, coap_message()) -> {ok, Ref}.
send_response(EndpointPid, Ref, Message) ->
    gen_server:cast(EndpointPid, {send_response, Message, {self(), Ref}}),
    {ok, Ref}.

-spec cancel_request(pid(), reference()) -> ok.
cancel_request(EndpointPid, Ref) ->
    gen_server:cast(EndpointPid, {cancel_request, {self(), Ref}}).

-spec generate_token() -> binary().
generate_token() -> generate_token(?TOKEN_LENGTH).

-spec generate_token(non_neg_integer()) -> binary().
generate_token(TKL) ->
    crypto:strong_rand_bytes(TKL).

%% gen_server.

% client
init([undefined, SocketModule, Socket, EpID]) ->
    TransArgs = #{sock=>Socket, sock_module=>SocketModule, ep_id=>EpID, endpoint_pid=>self()},
    % TRef = erlang:start_timer(?SCAN_INTERVAL, self(), scan),
    Timer = endpoint_timer:start_timer(?SCAN_INTERVAL, start_scan),
    {ok, #state{nextmid=first_mid(), rescnt=0, timer=Timer, trans_args=TransArgs}};

% server 
init([SupPid, SocketModule, Socket, EpID]) ->
    ok = proc_lib:init_ack({ok, self()}),
    {ok, HdlSupPid} = supervisor:start_child(SupPid, 
        #{id => ecoap_handler_sup,
            start => {ecoap_handler_sup, start_link, []},
            restart => permanent, 
          shutdown => infinity, 
          type => supervisor, 
          modules => [ecoap_handler_sup]}),
    TransArgs = #{sock=>Socket, sock_module=>SocketModule, ep_id=>EpID, endpoint_pid=>self(), handler_sup=>HdlSupPid, handler_regs=>#{}},
    % TRef = erlang:start_timer(?SCAN_INTERVAL, self(), scan),
    Timer = endpoint_timer:start_timer(?SCAN_INTERVAL, start_scan),
    gen_server:enter_loop(?MODULE, [], #state{nextmid=first_mid(), rescnt=0, timer=Timer, trans_args=TransArgs, handler_refs=#{}}).

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
    {Token, TrId} = maps:get(Receiver, Receivers, {undefined, undefined}),
    {noreply, State#state{tokens=maps:remove(Token, Tokens), trans=maps:remove(TrId, Trans), receivers=maps:remove(Receiver, Receivers)}};
handle_cast(shutdown, State) ->
    {stop, normal, State};
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
    % debug
    %io:format("incoming CON/NON request, TrId:~p~n", [TrId]),
    %io:format("MsgBin: ~p~n", [BinMessage]),
    % end of debug
    update_state(State, TrId,
        ecoap_exchange:received(BinMessage, TransArgs, create_exchange(TrId, undefined, State)));
% incoming CON(0) or NON(1) response
handle_info({datagram, BinMessage = <<?VERSION:2, 0:1, _:1, TKL:4, _Code:8, MsgId:16, Token:TKL/bytes, _/bytes>>},
    State=#state{trans=Trans, tokens=Tokens, trans_args=TransArgs=#{sock:=Socket, sock_module:=SocketModule, ep_id:=EpID}}) ->
	TrId = {in, MsgId},
    % debug
	%io:format("incoming CON/NON response, TrId:~p~n", [TrId]),
    %io:format("MsgBin: ~p~n", [BinMessage]),
    % end of debug
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
                    BinRST = coap_message:encode(coap_utils:rst(MsgId)),
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
            % ignore unexpected responses; ignore ack retransmission because the exchange has been removed
            {noreply, State}
    end;
% silently ignore other versions
handle_info({datagram, <<Ver:2, _/bytes>>}, State) when Ver /= ?VERSION ->
    % %io:format("unknown CoAP version~n"),
    {noreply, State};

handle_info(start_scan, State=#state{trans=Trans}) ->
    Trans2 = maps:filter(fun(_TrId, TrState) -> ecoap_exchange:not_expired(TrState) end, Trans),
    % io:format("scanning~n"),
    purge_state(State#state{trans=Trans2});

handle_info({timeout, TrId, Event}, State=#state{trans=Trans, trans_args=TransArgs}) ->
    %% code added by wilbur
    % %io:format("timeout, TrId:~p Event:~p~n", [TrId, Event]),
    %% end
    case maps:find(TrId, Trans) of
        {ok, TrState} -> update_state(State, TrId, ecoap_exchange:timeout(Event, TransArgs, TrState));
        error -> {noreply, State} % ignore unexpected responses
    end;

handle_info({request_complete, Receiver}, State=#state{tokens=Tokens, receivers=Receivers}) ->
    %io:format("request_complete~n"),
    {Token, _} = maps:get(Receiver, Receivers, {undefined, undefined}),
    {noreply, State#state{tokens=maps:remove(Token, Tokens), receivers=maps:remove(Receiver, Receivers)}};

% Only monitor possible observe handlers instead of every new spawned handler
% so that we can save some extra message traffic
handle_info({register_handler, ID, Pid}, State=#state{rescnt=Count, trans_args=TransArgs=#{handler_regs:=Regs}, handler_refs=Refs}) ->
    case maps:is_key(ID, Regs) of
        true -> {noreply, State};
        false ->
            io:format("register_ecoap_handler ~p for ~p~n", [Pid, ID]),
            Ref = erlang:monitor(process, Pid),
            {noreply, State#state{rescnt=Count+1, trans_args=TransArgs#{handler_regs:=maps:put(ID, Pid, Regs)}, handler_refs=maps:put(Ref, ID, Refs)}}
    end;

handle_info({'DOWN', Ref, process, _Pid, _Reason}, State=#state{rescnt=Count, trans_args=TransArgs=#{handler_regs:=Regs}, handler_refs=Refs}) ->
    case maps:find(Ref, Refs) of
        {ok, ID} -> 
            %% Code added by wilbur
            io:format("ecoap_handler_completed~n"),
            %% end
            {noreply, State#state{rescnt=Count-1, trans_args=TransArgs#{handler_regs:=maps:remove(ID, Regs)}, handler_refs=maps:remove(Ref, Refs)}};
        error -> 
            {noreply, State}
    end;
    
handle_info(_Info, State) ->
    error_logger:error_msg("unexpected info ~p received by ~p as ~p~n", [_Info, self(), ?MODULE]),
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%% Internal
make_new_request(Message=#coap_message{token=Token}, Receiver, State=#state{tokens=Tokens, nextmid=MsgId, receivers=Receivers}) ->
    % in case this is a request using previous token, we need to remove the outdated receiver reference first
    Receivers2 = maps:put(Receiver, {Token, {out, MsgId}}, maps:remove(maps:get(Token, Tokens, undefined), Receivers)),
    Tokens2 = maps:put(Token, Receiver, Tokens),
    make_new_message(Message, Receiver, State#state{tokens=Tokens2, receivers=Receivers2}).

make_new_message(Message, Receiver, State=#state{nextmid=MsgId}) ->
    make_message({out, MsgId}, Message#coap_message{id=MsgId}, Receiver, State#state{nextmid=next_mid(MsgId)}).

make_message(TrId, Message, Receiver, State=#state{trans_args=TransArgs}) ->
    update_state(State, TrId,
        ecoap_exchange:send(Message, TransArgs, init_exchange(TrId, Receiver))).

make_new_response(Message=#coap_message{id=MsgId}, Receiver, State=#state{trans=Trans, trans_args=TransArgs}) ->
    %io:format("The response: ~p~n", [Message]),
    case maps:find({in, MsgId}, Trans) of
        {ok, TrState} ->
            %% Note by wilbur: coap_transport:awaits_response is used to 
            %% check if we are in the case that
            %% we received a CON request, have its state stored, but did not send its ACK yet
            case ecoap_exchange:awaits_response(TrState) of
                true ->
                %% Note by wilbur: we are about to send ACK
                %% By calling coap_transport:send, we make the state change to pack_sent
                    update_state(State, {in, MsgId},
                        ecoap_exchange:send(Message, TransArgs, TrState));
                false ->
                    % Note by wilbur:
                    % send separate response or observe notification
                    % TODO: decide whether to send a CON notification considering other notifications may be in transit
                    %       and how to keep the retransimit counter for a newer notification when the former one timed out
                    make_new_message(Message, Receiver, State)
            end;
            %% Note by wilbur: why is the separate response by default a CON msg? 
            %% Because in this implementation a response for CON req uses the same msg type 
            %% until it is modified before being sent as an ACK
        error ->
            % Note by wilbur:
            % send NON response
            make_new_message(Message, Receiver, State)
    end.

first_mid() ->
    _ = rand:seed(exs1024),
    rand:uniform(?MAX_MESSAGE_ID).

next_mid(MsgId) ->
    if
        MsgId < ?MAX_MESSAGE_ID -> MsgId + 1;
        true -> 1 % or 0?
    end.

% find or initialize a new exchange
create_exchange(TrId, Receiver, #state{trans=Trans}) ->
    case maps:find(TrId, Trans) of
        {ok, TrState} -> TrState;
        error -> init_exchange(TrId, Receiver)
    end.

% init_exchange(TrId, undefined) ->
%     ecoap_exchange:init(TrId, undefined);
init_exchange(TrId, Receiver) ->
    ecoap_exchange:init(TrId, Receiver).

update_state(State=#state{trans=Trans}, TrId, undefined) ->
    Trans2 = maps:remove(TrId, Trans),
    {noreply, State#state{trans=Trans2}};
    % purge_state(State#state{trans=Trans2});
update_state(State=#state{trans=Trans, timer=Timer}, TrId, TrState) ->
    Timer2 = endpoint_timer:kick_timer(Timer),
    Trans2 = maps:put(TrId, TrState, Trans),
    {noreply, State#state{trans=Trans2, timer=Timer2}}.

purge_state(State=#state{tokens=Tokens, trans=Trans, rescnt=Count, timer=Timer}) ->
    case {maps:size(Tokens) + maps:size(Trans) + Count, endpoint_timer:is_timeout(Timer)} of
        {0, true} -> 
            % io:format("All trans expired~n"),
            {stop, normal, State};
        _Else -> 
            Timer2 = endpoint_timer:restart_timer(Timer),
            % io:format("Ongoing trans exist~n"),
            {noreply, State#state{timer=Timer2}}
    end.
