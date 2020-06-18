-module(ecoap_dtls_listener_sup).
-behaviour(supervisor).

-export([start_link/6, close/1]).
-export([init/1]).
-export([start_acceptor/1]).
-export([count_acceptors/1]).

%% TODO: consider acceptor & supervisor pair or acceptor as supervisor pattern
%% check issue and discussion from Cowboy repo
%% Problem: 1. add complexity for supervision tree
%%			2. if acceptor itself is a supervisor that starts connection process, then how to deal with blocking (during accepting)

%% TODO: with OTP 21 erts 10.3.2, after stop an application that holds a DTLS listen socket, the socket remains in closed state
%% and can not be open again
%% How to reproduce: 
%% 1. call ecoap:start_dtls/2, 2. call ecoap:stop_dtls/1, 3. call ecoap:start_dtls/2 with same params as in 1.
%% Observation: 
%% 1. DTLS listen port still observable using inet:i() after stop ecoap
%% 2. corresponding process still observable in ssl application 

start_link(_ServerSupPid, Name, TransOpts, ProtoConfig, TimeOut, NumAcceptors) ->
	ok = ecoap_registry:set_new_listener_config(Name, TransOpts, ProtoConfig),
	supervisor:start_link({local, Name}, ?MODULE, [Name, TransOpts, ProtoConfig, TimeOut, NumAcceptors]).

init([Name, TransOpts, ProtoConfig, TimeOut, NumAcceptors]) ->
	% temporary fix to: when listen socket holder process crashes the socket is not closed properly
	_ = close(Name),
	% end of fix
	ListenSocket = case ssl:listen(0, ecoap_socket:socket_opts(dtls, TransOpts)) of
		{ok, Socket} -> 
			Socket;
		{error, Error} ->
			listener_error(Name, TransOpts, Error)                                                                                                                                                                                                                                                                                                                                                                                                                                        
	end,
	% temporary fix to: when listen socket holder process crashes the socket is not closed properly
	persistent_term:put({?MODULE, Name}, ListenSocket),
	% end of fix
	{ok, {Addr, Port}} = ssl:sockname(ListenSocket),
	logger:log(info, "ecoap listen on DTLS ~s:~p", [inet:ntoa(Addr), Port]),
	ok = ecoap_registry:set_listener(Name, self()),
	_ = start_acceptors(Name, NumAcceptors),
	Procs = [
			#{id => ecoap_dtls_socket, 
			start => {ecoap_dtls_socket, start_link, [Name, ListenSocket, ProtoConfig, TimeOut]},
			restart => temporary,
			shutdown => 5000,
			type => worker,
			modules => [ecoap_dtls_socket]}],
	{ok, {#{strategy => simple_one_for_one, intensity => 1, period => 5}, Procs}}.		

start_acceptors(Name, NumAcceptors) ->
	spawn_link(fun() -> [start_acceptor(Name) || _ <- lists:seq(1, NumAcceptors)] end).

start_acceptor(Name) ->
	supervisor:start_child(Name, []).

count_acceptors(Name) ->
    proplists:get_value(active, supervisor:count_children(Name), 0).

% temporary fix to: when listen socket holder process crashes the socket is not closed properly
close(Name) ->
    case catch persistent_term:get({?MODULE, Name}) of
        {'EXIT', _} -> 
			ok;
        Sock ->
			persistent_term:erase({?MODULE, Name}),
            ssl:close(Sock)
    end.
% end of fix

-spec listener_error(atom(), any(), any()) -> no_return().
listener_error(Name, TransOpts, Error) ->
	Reason = format_error(Error),
	logger:log(error, "Failed to start ecoap listener ~p in ~p:listen (~999999p) for reason ~p (~s)~n", 
				[Name, ?MODULE, TransOpts, Reason, inet:format_error(Reason)]),
	exit({listen_error, Name, Reason}).    

format_error({shutdown, {error, Reason}}) -> Reason;
format_error(Reason) -> Reason.
