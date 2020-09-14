-module(ecoap_registry).
-behaviour(gen_server).

%% API.
-export([start_link/0, get_links/0, register_handler/1, unregister_handler/1, cleanup_handlers/0, match_handler/1]).

-export([set_listener/2, set_new_listener_config/3, set_protocol_config/2, set_transport_opts/2]).
-export([get_listener/1, get_listeners/0, get_protocol_config/1, get_transport_opts/1]).
-export([cleanup_listener_opts/1]).

%% gen_server.
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-record(state, {
    monitors = [] :: list()
}).

-type route_rule() :: {[binary()], module()}.
-export_type([route_rule/0]).

-define(HANDLER_TAB, ecoap_routes).
-define(CONFIG_TAB, ecoap_config).

%% API.

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec register_handler([route_rule()]) -> ok.
register_handler(Regs) when is_list(Regs) -> 
    gen_server:call(?MODULE, {register, process_regs(Regs)}).

-spec unregister_handler([binary()]) -> ok.
unregister_handler(Prefix) ->
    gen_server:call(?MODULE, {unregister, Prefix}).

-spec cleanup_handlers() -> ok.
cleanup_handlers() ->
    gen_server:call(?MODULE, cleanup_handlers).

-spec get_links() -> list().
get_links() ->
    lists:usort(get_links(ets:tab2list(?HANDLER_TAB))).
    % lists:usort(get_links(?HANDLER_TAB)).

-spec match_handler([binary()]) -> {route_rule(), [binary()]} | undefined.
match_handler(Uri) -> match_handler(Uri, ?HANDLER_TAB).

-spec set_listener(atom(), pid()) -> ok.
set_listener(Name, Pid) ->
    gen_server:call(?MODULE, {set_listener, Name, Pid}).

-spec set_new_listener_config(atom(), any(), map()) -> ok.
set_new_listener_config(Name, TransOpts, ProtoConfig) ->
    gen_server:call(?MODULE, {set_new_listener_config, Name, TransOpts, ProtoConfig}).

-spec set_protocol_config(atom(), map()) -> ok.
set_protocol_config(Name, ProtoConfig) ->
    gen_server:call(?MODULE, {set_protocol_config, Name, ProtoConfig}).

-spec set_transport_opts(atom(), any()) -> ok.
set_transport_opts(Name, TransOpts) ->
    gen_server:call(?MODULE, {set_transport_opts, Name, TransOpts}).

-spec get_listener(atom()) -> pid().
get_listener(Name) ->
    ets:lookup_element(?CONFIG_TAB, {listener, Name}, 2).

-spec get_listeners() -> [{atom(), pid()}].
get_listeners() ->
    [{Name, Pid} || [Name, Pid] <- ets:match(?CONFIG_TAB, {{listener, '$1'}, '$2'})].

-spec get_protocol_config(atom()) -> map().
get_protocol_config(Name) ->
    ets:lookup_element(?CONFIG_TAB, {protocol_config, Name}, 2).

-spec get_transport_opts(atom()) -> any().
get_transport_opts(Name) ->
    ets:lookup_element(?CONFIG_TAB, {transport_opts, Name}, 2).

-spec cleanup_listener_opts(atom()) -> ok.
cleanup_listener_opts(Name) ->
    _ = ets:delete(?CONFIG_TAB, {transport_opts, Name}),
    _ = ets:delete(?CONFIG_TAB, {protocol_config, Name}),
    _ = ets:delete(?CONFIG_TAB, {listener, Name}),
    ok.

% -spec clear_registry() -> true.
% clear_registry() -> ets:delete_all_objects(?HANDLER_TAB).

% select an entry with a longest prefix
% this allows user to have one handler for "foo" and another for "foo/bar"

% one can define route with ending wildcard as <<"*">>, see test case at the end of file
% if wildcard is not explicitly defined, a request that matches prefix but has non-empty suffix will be considered as not found
% in other words, routes without given wildcard are matched exactly one to one
% one can also define the same route path with and without wildcard at the same time and let them point to different handlers

% current limitation:
% we have to search the whole input URI even when no route matches / no wildcard is defined
% this is because we are using a ETS table which is a plain key-value store 
% if we use a tree like structure it is easier to iterate it from the root and eliminate unnecessary searching

match_handler(Key, Tab) ->
    case ets:lookup(Tab, Key) of
        [{Prefix, Match}] -> 
            return_match(Prefix, [], Match);
        [] -> 
            match_handler_with_wildcard(Key, Tab)
    end.

match_handler_with_wildcard(Key, Tab) ->
    case match([], Key, Tab) of
        {Prefix, Match} -> 
            return_match(Prefix, uri_suffix(Prefix, Key), Match);
        _ -> 
            undefined
    end.

match([Val], _, _) ->
    Val;
match([], [], _) ->
    undefined;
match([], Key, Tab) ->
    NewKey = lists:droplast(Key),
    match(ets:lookup(Tab, NewKey), NewKey, Tab).

uri_suffix(Prefix, Uri) ->
    lists:nthtail(length(Prefix), Uri).

% no wildcard defined and no wildcard fetched
return_match(Prefix, [], {normal, Module}) ->
    {{Prefix, Module}, []};
% no wildcard defined and but wildcard fetched
return_match(_, _, {normal, _}) ->
    undefined;
% wildcard defined and wildcard fetched
return_match(Prefix, Suffix, {wildcard, Module}) ->
    {{Prefix, Module}, Suffix};
% same as before
return_match(Prefix, [], Match) when is_list(Match) ->
    return_match(Prefix, [], lists:keyfind(normal, 1, Match));
return_match(Prefix, Suffix, Match) when is_list(Match) ->
    return_match(Prefix, Suffix, lists:keyfind(wildcard, 1, Match)).

% ask each handler to provide a link list
% get_links(Reg) ->
%     ets:foldl(
%         fun({Prefix, Module, Args}, Acc) -> get_links(Prefix, Module, Args) ++ Acc end,
%         [], Reg).

get_links(Reg) ->
    lists:foldl(
        fun({Prefix, Match}, Acc) -> get_links(Prefix, Match) ++ Acc end,
        [], Reg).


get_links(Prefix, Match) when is_list(Match) ->
    [get_links(Prefix, M) || M <- Match];
get_links(Prefix, {_, Module}) ->
    % for each pattern ask the handler to provide a list of resources
    call_coap_discover(Module, Prefix).

call_coap_discover(Module, Prefix) -> 
    case erlang:function_exported(Module, coap_discover, 1) of
        true -> Module:coap_discover(Prefix);
        false -> [{absolute, Prefix, []}]
    end.

%% gen_server.
init([]) ->
    ok = register_well_known(),
    ListenerMonitors = [{{erlang:monitor(process, Pid), Pid}, {listener, Ref}} ||
        [Ref, Pid] <- ets:match(?CONFIG_TAB, {{listener, '$1'}, '$2'})],
    {ok, #state{monitors=ListenerMonitors}}.

% routing
handle_call({register, Regs}, _From, State) ->
    ok = load_handlers(Regs),
    ets:insert(?HANDLER_TAB, Regs),
    {reply, ok, State};    
handle_call({unregister, Prefix}, _From, State) ->
    ets:delete(?HANDLER_TAB, Prefix),
    {reply, ok, State};
handle_call(cleanup_handlers, _From, State) ->
    ets:delete_all_objects(?HANDLER_TAB),
    ok = register_well_known(),
    {reply, ok, State};
% protocol and transport
handle_call({set_listener, Name, Pid}, _From, State0) ->
    State = set_monitored_process({listener, Name}, Pid, State0),
    {reply, ok, State};
handle_call({set_new_listener_config, Name, TransOpts, ProtoConfig}, _From, State) ->
    ets:insert_new(?CONFIG_TAB, {{transport_opts, Name}, TransOpts}),
    ets:insert_new(?CONFIG_TAB, {{protocol_config, Name}, ProtoConfig}),
    {reply, ok, State};
handle_call({set_protocol_config, Name, ProtoConfig}, _From, State) ->
    ets:insert(?CONFIG_TAB, {{protocol_config, Name}, ProtoConfig}),
    {reply, ok, State};
handle_call({set_transport_opts, Name, TransOpts}, _From, State) ->
    ets:insert(?CONFIG_TAB, {{transport_opts, Name}, TransOpts}),
    {reply, ok, State};
handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', MonitorRef, process, Pid, Reason}, State=#state{monitors=Monitors}) ->
    {_, TypeRef} = lists:keyfind({MonitorRef, Pid}, 1, Monitors),
    ok = case {TypeRef, Reason} of
        {{listener, Name}, normal} ->
            cleanup_listener_opts(Name);
        {{listener, Name}, shutdown} ->
            cleanup_listener_opts(Name);
        {{listener, Name}, {shutdown, _}} ->
            cleanup_listener_opts(Name);
        _ ->
            _ = ets:delete(?CONFIG_TAB, TypeRef),
            ok
    end,
    Monitors2 = lists:keydelete({MonitorRef, Pid}, 1, Monitors),
    {noreply, State#state{monitors=Monitors2}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

set_monitored_process(Key, Pid, State=#state{monitors=Monitors0}) ->
    %% First we cleanup the monitor if a residual one exists.
    %% This can happen during crashes when the restart is faster
    %% than the cleanup.
    Monitors = case lists:keytake(Key, 2, Monitors0) of
        false ->
            Monitors0;
        {value, {{OldMonitorRef, _}, _}, Monitors1} ->
            true = erlang:demonitor(OldMonitorRef, [flush]),
            Monitors1
    end,
    %% Then we unconditionally insert in the ets table.
    %% If residual data is there, it will be overwritten.
    true = ets:insert(?CONFIG_TAB, {Key, Pid}),
    %% Finally we start monitoring this new process.
    MonitorRef = erlang:monitor(process, Pid),
    State#state{monitors=[{{MonitorRef, Pid}, Key}|Monitors]}.

% in case the system is not run as release, we should manually load all module files
load_handlers(Regs) ->
    case code:ensure_modules_loaded([Module || {_, {_, Module}} <- Regs]) of
        ok -> ok;
        {error, [{Module, What}]} -> logger:log(error, "Fail to load handler module: ~p~n", [{Module, What}])
    end.

process_regs(Regs) ->
    NormalizedRegs = lists:map(fun process_reg/1, Regs),
    process_dup(lists:keysort(1, NormalizedRegs), []).

process_reg({[_|_]=Prefix, Module}) ->
    case lists:last(Prefix) of 
        <<"*">> -> {lists:droplast(Prefix), {wildcard, Module}}; 
        _ -> {Prefix, {normal, Module}}
    end;
% for root resource where Prefix = []
process_reg({Prefix, Module}) -> 
    {Prefix, {normal, Module}}.

process_dup([{Key, Val2} | Rest], [{Key, Val1} | Acc]) ->
    process_dup(Rest, [{Key, [Val2 | make_list(Val1)]} | Acc]);
process_dup([Elem | Rest], Acc) ->
    process_dup(Rest, [Elem | Acc]);
process_dup([], Acc) ->
    Acc.

make_list(Val) when is_list(Val) -> Val;
make_list(Val) -> [Val].

register_well_known() ->
    Reg = process_regs([{[<<".well-known">>, <<"core">>], ecoap_resource_directory}]),
    true = ets:insert(?HANDLER_TAB, Reg),
    ok = load_handlers(Reg).

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

match_test_() ->
    Tab = ets:new(ecoap_registry, [set]),
    Regs = [{[], root},
            {[<<"foo">>], foo},
            {[<<"foo">>, <<"bar">>], foobar},
            {[<<"bar">>, <<"foo">>], barfoo},
            {[<<"bar">>, <<"foo">>, <<"*">>], barfoo_wild},
            {[<<"b">>, <<"c">>, <<"*">>], bc_wild},
            {[<<"b">>, <<"c">>, <<"d">>], bcd}
    ],
    ets:insert(Tab, process_regs(Regs)),
    [?_assertEqual(undefined, match_handler([<<"bar">>], Tab)),
    ?_assertEqual({{[<<"foo">>], foo}, []}, match_handler([<<"foo">>], Tab)),
    ?_assertEqual({{[<<"foo">>, <<"bar">>], foobar}, []}, match_handler([<<"foo">>, <<"bar">>], Tab)),
    ?_assertEqual(undefined, match_handler([<<"foo">>, <<"bar">>, <<"hoge">>], Tab)),
    ?_assertEqual({{[<<"bar">>, <<"foo">>], barfoo}, []}, match_handler([<<"bar">>, <<"foo">>], Tab)),
    ?_assertEqual({{[<<"bar">>, <<"foo">>], barfoo_wild}, [<<"hoge">>]}, match_handler([<<"bar">>, <<"foo">>, <<"hoge">>], Tab)),
    ?_assertEqual({{[<<"b">>, <<"c">>], bc_wild}, [<<"extra">>]}, match_handler([<<"b">>, <<"c">>, <<"extra">>], Tab))
    ].

match_root_test_() ->
    Tab = ets:new(ecoap_registry, [set]),
    Regs = [{[<<"*">>], root},
            {[<<"hoge">>, <<"*">>], hoge},
            {[<<"hana">>], hana}
    ],
    ets:insert(Tab, process_regs(Regs)),
    [?_assertEqual({{[], root}, []}, match_handler([], Tab)),
    ?_assertEqual({{[], root}, [<<"foo">>, <<"bar">>]}, match_handler([<<"foo">>, <<"bar">>], Tab)),
    ?_assertEqual({{[<<"hoge">>], hoge}, []}, match_handler([<<"hoge">>], Tab)),
    ?_assertEqual({{[<<"hoge">>], hoge}, [<<"gugi">>]}, match_handler([<<"hoge">>, <<"gugi">>], Tab)),
    ?_assertEqual(undefined, match_handler([<<"hana">>, <<"boo">>], Tab))
    ].

-endif.
