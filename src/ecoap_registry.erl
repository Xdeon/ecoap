-module(ecoap_registry).
-behaviour(gen_server).

%% API.
-export([start_link/0, get_links/0, register_handler/3, unregister_handler/1, match_handler/1, clear_registry/0]).
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

-spec register_handler([binary()], module(), _) -> ok | {error, duplicated}.
register_handler(Prefix, Module, Args) ->
    gen_server:call(?MODULE, {register, Prefix, Module, Args}).

-spec unregister_handler([binary()]) -> ok .
unregister_handler(Prefix) ->
    gen_server:call(?MODULE, {unregister, Prefix}).

-spec get_links() -> list().
get_links() ->
    lists:usort(get_links(ets:tab2list(?HANDLER_TAB))).
    % lists:usort(get_links(?HANDLER_TAB)).

-spec match_handler([binary()]) -> {[binary()], module(), _} | undefined.
% match_handler(Uri) -> match_handler(Uri, ets:tab2list(?HANDLER_TAB)).
match_handler(Uri) -> match_handler(Uri, ?HANDLER_TAB).

-spec clear_registry() -> true.
clear_registry() -> ets:delete_all_objects(?HANDLER_TAB).

% match_handler(_Uri, []) ->
%     undefined;
% match_handler(Uri, [{Prefix, Module, Args} | T]) ->
%     case match_prefix(Prefix, Uri) of
%         true  -> {Prefix, Module, Args};
%         false -> match_handler(Uri, T)
%     end.

% match_prefix([], []) ->
%     true;
% match_prefix([], _) ->
%     true;
% match_prefix([H|T1], [H|T2]) ->
%     match_prefix(T1, T2);
% match_prefix(_Prefix, _Uri) ->
%     false.

% TODO: more optimization for matching en entry
match_handler(Uri, Reg) ->
    % avoid traversing the table when URI could directly match an entry
    % however if this is not the case, an extra lookup is needed before searching the entire table
    case ets:lookup(Reg, Uri) of
        [Elem] -> Elem;
        [] ->
            ets:foldl(
                fun(Elem={Prefix, _, _}, Found) ->
                    case lists:prefix(Prefix, Uri) of
                        true -> one_with_longer_uri(Elem, Found);
                        false -> Found
                    end
                end,
                undefined, Reg)
    end.

% match_handler(Uri, Reg) ->
%     lists:foldl(
%         fun(Elem={Prefix, _, _}, Found) ->
%             case lists:prefix(Prefix, Uri) of
%                 true -> one_with_longer_uri(Elem, Found);
%                 false -> Found
%             end
%         end,
%         undefined, Reg).

% select an entry with a longest prefix
% this allows user to have one handler for "foo" and another for "foo/bar"
one_with_longer_uri(Elem1, undefined) -> Elem1;
one_with_longer_uri(Elem1={Prefix, _, _}, {Match, _, _}) when length(Prefix) > length(Match) -> Elem1;
one_with_longer_uri(_Elem1, Elem2) -> Elem2.

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

handle_call({register, Prefix, Module, Args}, _From, State) ->
    ets:insert(?HANDLER_TAB, {Prefix, Module, Args}),
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
