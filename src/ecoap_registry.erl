-module(ecoap_registry).
-behaviour(gen_server).

%% API.
-export([start_link/0, register_handler/3, unregister_handler/1, match_handler/1, clear_registry/0]).

%% gen_server.
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-record(state, {
}).

-define(HANDLER_TAB, ?MODULE).
-include("coap_def.hrl").

%% API.

-spec start_link() -> {ok, pid()}.
start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec register_handler(list(binary()), module(), _) -> ok | {error, duplicated}.
register_handler(Prefix, Module, Args) ->
    gen_server:call(?MODULE, {register, Prefix, Module, Args}).

-spec unregister_handler(list(binary())) -> ok .
unregister_handler(Prefix) ->
    gen_server:call(?MODULE, {unregister, Prefix}).

-spec match_handler(list(binary())) -> {list(binary()), module(), _} | undefined.
match_handler(Uri) -> match_handler(Uri, ets:tab2list(?HANDLER_TAB)).

-spec clear_registry() -> true.
clear_registry() -> ets:delete_all_objects(?HANDLER_TAB).

match_handler(_Uri, []) ->
    undefined;
match_handler(Uri, [{Prefix, Module, Args} | T]) ->
    case match_prefix(Prefix, Uri) of
        true  -> {Prefix, Module, Args};
        false -> match_handler(Uri, T)
    end.

match_prefix([], []) ->
    true;
match_prefix([], _) ->
    false;
match_prefix([H|T1], [H|T2]) ->
    match_prefix(T1, T2);
match_prefix(_Prefix, _Uri) ->
    false.

%% gen_server.
init([]) ->
	% _ = ets:new(?HANDLER_TAB, [set, named_table, protected]),
	{ok, #state{}}.

handle_call({register, Prefix, Module, Args}, _From, State) ->
    case ets:member(?HANDLER_TAB, Prefix) of
        true  -> {reply, {error, duplicated}, State};
        false -> ets:insert(?HANDLER_TAB, {Prefix, Module, Args}),
                 {reply, ok, State}
    end;
handle_call({unregister, Prefix}, _From, State) ->
    ets:delete(?HANDLER_TAB, Prefix),
	{reply, ok, State};
handle_call(_Request, _From, State) ->
	{reply, ignored, State}.

handle_cast(_Msg, State) ->
	{noreply, State}.

handle_info(_Info, State) ->
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.
