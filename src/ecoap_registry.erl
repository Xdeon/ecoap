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

%% API.

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec register_handler([{[binary()], module()}]) -> ok.
register_handler(Regs) when is_list(Regs) -> 
    gen_server:call(?MODULE, {register, Regs}).

-spec unregister_handler([binary()]) -> ok.
unregister_handler(Prefix) ->
    gen_server:call(?MODULE, {unregister, Prefix}).

-spec get_links() -> list().
get_links() ->
    lists:usort(get_links(ets:tab2list(?HANDLER_TAB))).
    % lists:usort(get_links(?HANDLER_TAB)).

-spec match_handler([binary()]) -> {[binary()], module()} | undefined.
match_handler(Uri) -> match_handler(Uri, ?HANDLER_TAB).

-spec clear_registry() -> true.
clear_registry() -> ets:delete_all_objects(?HANDLER_TAB).

% select an entry with a longest prefix
% this allows user to have one handler for "foo" and another for "foo/bar"

match_handler(Key, Tab) ->
    match(ets:lookup(Tab, Key), Key, Tab).

match([Val], _, _) ->
    Val;
match([], [], _) ->
    undefined;
match([], Key, Tab) ->
    NewKey = lists:droplast(Key),
    match(ets:lookup(Tab, NewKey), NewKey, Tab).

% ask each handler to provide a link list
% get_links(Reg) ->
%     ets:foldl(
%         fun({Prefix, Module, Args}, Acc) -> get_links(Prefix, Module, Args) ++ Acc end,
%         [], Reg).

get_links(Reg) ->
    lists:flatten(lists:foldl(
        fun({Prefix, Module}, Acc) -> [get_links(Prefix, Module)|Acc] end,
        [], Reg)).

get_links(Prefix, Module) ->
    % for each pattern ask the handler to provide a list of resources
    call_coap_discover(Module, Prefix).

call_coap_discover(Module, Prefix) -> 
    case erlang:function_exported(Module, coap_discover, 1) of
        true -> Module:coap_discover(Prefix);
        false -> [{absolute, Prefix, []}]
    end.

%% gen_server.
init([]) ->
    spawn(fun() -> ecoap_registry:register_handler([{[<<".well-known">>, <<"core">>], resource_directory}]) end),
    {ok, #state{}}.

handle_call({register, Reg}, _From, State) ->
    load_handlers(Reg),
    ets:insert(?HANDLER_TAB, Reg),
    {reply, ok, State};    
handle_call({unregister, Prefix}, _From, State) ->
    ets:delete(?HANDLER_TAB, Prefix),
    {reply, ok, State};
handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

% in case the system is not run as release, we should manually load all module files
load_handlers(Reg) ->
    lists:foreach(fun({_, Module}) -> 
        case code:ensure_loaded(Module) of
            {module, Module} -> ok;
            {error, embedded} -> ok;
            {error, Error} -> error_logger:error_msg("handler module ~p load fail: ~p~n", [Module, Error])
        end end, Reg).

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

match_test_() ->
    Tab = ets:new(ecoap_registry, [set]),
    ets:insert(Tab, {[<<"foo">>], ?MODULE, undefined}),
    ets:insert(Tab, {[<<"foo">>, <<"bar">>], ?MODULE, undefined}),
    [?_assertEqual(undefined, match_handler([<<"bar">>], Tab)),
    ?_assertEqual({[<<"foo">>], ?MODULE, undefined}, match_handler([<<"foo">>], Tab)),
    ?_assertEqual({[<<"foo">>, <<"bar">>], ?MODULE, undefined}, match_handler([<<"foo">>, <<"bar">>], Tab)),
    ?_assertEqual({[<<"foo">>, <<"bar">>], ?MODULE, undefined}, match_handler([<<"foo">>, <<"bar">>, <<"hoge">>], Tab))
    ].

match_root_test_() ->
    Tab = ets:new(ecoap_registry, [set]),
    ets:insert(Tab, {[], ?MODULE, undefined}),
    ets:insert(Tab, {[<<"hoge">>], ?MODULE, undefined}),
    [?_assertEqual({[], ?MODULE, undefined}, match_handler([], Tab)),
    ?_assertEqual({[], ?MODULE, undefined}, match_handler([<<"foo">>, <<"bar">>], Tab)),
    ?_assertEqual({[<<"hoge">>], ?MODULE, undefined}, match_handler([<<"hoge">>], Tab)),
    ?_assertEqual({[<<"hoge">>], ?MODULE, undefined}, match_handler([<<"hoge">>, <<"gugi">>], Tab))
    ].

-endif.
