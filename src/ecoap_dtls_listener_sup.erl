-module(ecoap_dtls_listener_sup).
-behaviour(supervisor).

-export([start_link/3]).
-export([init/1]).
-export([start_listener/1]).
-export([count_acceptors/1]).

-include("ecoap.hrl").

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

start_link(_ServerSupPid, Name, Config) ->
	supervisor:start_link({local, Name}, ?MODULE, [Name, Config]).

init([Name, Config]) ->
	TransOpts0 = maps:get(transport_opts, Config, []),
	TransOpts = [{port, ?DEFAULT_COAPS_PORT}|TransOpts0],
	ProtoConfig = maps:get(protocol_config, Config, #{}),
	TimeOut = maps:get(handshake_timeout, Config, 5000),
	NumAcceptors = maps:get(num_acceptors, Config, 10),
	ListenSocket = case ssl:listen(0, ecoap_config:merge_sock_opts(ecoap_dtls_socket:default_dtls_transopts(), TransOpts)) of
		{ok, Socket} -> 
			Socket;
		{error, Reason} -> 
			logger:log(error, "Failed to start ecoap listener ~p in ~p:listen (~999999p) for reason ~p~n", 
				[Name, ?MODULE, TransOpts, Reason]),
			exit({listen_error, Name, Reason})
	end,
	_ = start_listeners(Name, NumAcceptors),
	Procs = [
			#{id => ecoap_dtls_socket, 
			start => {ecoap_dtls_socket, start_link, [Name, ListenSocket, ProtoConfig, TimeOut]},
			restart => temporary,
			shutdown => 5000,
			type => worker,
			modules => [ecoap_dtls_socket]}],
	{ok, {#{strategy => simple_one_for_one, intensity => 1, period => 5}, Procs}}.		

start_listeners(Name, NumAcceptors) ->
	spawn_link(fun() -> [start_listener(Name) || _ <- lists:seq(1, NumAcceptors)] end).

start_listener(Name) ->
	supervisor:start_child(Name, []).

count_acceptors(Name) ->
    proplists:get_value(active, supervisor:count_children(Name), 0).
