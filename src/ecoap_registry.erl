-module(ecoap_registry).
-behaviour(gen_server).

%% API.
-export([start_link/0, get_links/0, register_handler/1, unregister_handler/1, match_handler/1, clear_registry/0]).
% -compile([export_all]).

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
-include_lib("ecoap_common/include/coap_def.hrl").

%% API.

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

% -spec register_handler([{[binary(), module(), _]}]) -> ok.
register_handler(Regs) when is_list(Regs) -> 
    gen_server:call(?MODULE, {register, Regs}).

-spec unregister_handler([binary()]) -> ok.
unregister_handler(Prefix) ->
    gen_server:call(?MODULE, {unregister, Prefix}).

-spec get_links() -> list().
get_links() ->
    lists:usort(get_links(ets:tab2list(?HANDLER_TAB))).
    % lists:usort(get_links(?HANDLER_TAB)).

-spec match_handler([binary()]) -> {[binary()], module(), _} | undefined.
match_handler(Uri) -> match_handler(Uri, ?HANDLER_TAB).

-spec clear_registry() -> true.
clear_registry() -> ets:delete_all_objects(?HANDLER_TAB).

% select an entry with a longest prefix
% this allows user to have one handler for "foo" and another for "foo/bar"

match_handler([], Reg) ->
    match(Reg, [], undefined);
match_handler(Uri, Reg) ->
    match(Reg, Uri, match_handler(lists:droplast(Uri), Reg)).

match(Tab, Key, Default) ->
    case ets:lookup(Tab, Key) of
        [Val] -> Val;
        [] -> Default
    end.

% ask each handler to provide a link list
% get_links(Reg) ->
%     ets:foldl(
%         fun({Prefix, Module, Args}, Acc) -> get_links(Prefix, Module, Args) ++ Acc end,
%         [], Reg).

get_links(Reg) ->
    lists:foldl(
        fun({Prefix, Module, Args}, Acc) -> get_links(Prefix, Module, Args) ++ Acc end,
        [], Reg).

get_links(Prefix, Module, Args) ->
    case catch {ok, apply(Module, coap_discover, [Prefix, Args])} of
        % for each pattern ask the handler to provide a list of resources
        {'EXIT', _} -> [];
        {ok, Response} -> Response
    end.

%% gen_server.
init([]) ->
    % _ = ets:new(?HANDLER_TAB, [set, named_table, protected]),
    ets:insert(?HANDLER_TAB, {[<<".well-known">>, <<"core">>], resource_directory, undefined}),
    {ok, #state{}}.

handle_call({register, Reg}, _From, State) ->
    ets:insert(?HANDLER_TAB, Reg),
    {reply, ok, State};    
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

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

match_test_() ->
    Tab = ets:new(ecoap_registry, [set]),
    ets:insert(Tab, {[<<"foo">>], ?MODULE, undefined}),
    ets:insert(Tab, {[<<"foo">>, <<"bar">>], ?MODULE, undefined}),
    [?_assertEqual({[<<"foo">>], ?MODULE, undefined}, match_handler([<<"foo">>], Tab)),
    ?_assertEqual({[<<"foo">>, <<"bar">>], ?MODULE, undefined}, match_handler([<<"foo">>, <<"bar">>], Tab)),
    ?_assertEqual({[<<"foo">>, <<"bar">>], ?MODULE, undefined}, match_handler([<<"foo">>, <<"bar">>, <<"hoge">>], Tab))
    ].

match_root_test_() ->
    Tab = ets:new(ecoap_registry, [set]),
    ets:insert(Tab, {[], ?MODULE, undefined}),
    [?_assertEqual({[], ?MODULE, undefined}, match_handler([<<"foo">>, <<"bar">>], Tab)),
    ?_assertEqual({[], ?MODULE, undefined}, match_handler([], Tab))
    ].

-endif.
