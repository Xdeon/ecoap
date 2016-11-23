-module(sender).
-behaviour(gen_server).

%% API.
-export([start_link/1]).

%% gen_server.
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-record(state, {
	sock = undefined :: inet:socket()
}).

%% API.

-spec start_link(inet:socket()) -> {ok, pid()}.
start_link(Socket) ->
	gen_server:start_link(?MODULE, [Socket], []).

%% gen_server.

init([Socket]) ->
	{ok, #state{sock=Socket}}.

handle_call(_Request, _From, State) ->
	{reply, ignored, State}.

handle_cast(_Msg, State) ->
	{noreply, State}.

handle_info({datagram, {PeerIP, PeerPortNo}, Data}, State=#state{sock=Socket}) ->
	ok = gen_udp:send(Socket, PeerIP, PeerPortNo, Data),
    {noreply, State};
handle_info(_Info, State) ->
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.
