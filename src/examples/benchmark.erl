-module(benchmark).
-export([coap_discover/2, coap_get/4, coap_post/4, coap_put/4, coap_delete/3, coap_observe/4, coap_unobserve/1, handle_info/2, coap_ack/2]).
-export([start/0, stop/0]).

-include("coap_def.hrl").
-behaviour(coap_resource).

start() ->
    {ok, _} = application:ensure_all_started(ecoap),
    ecoap_registry:register_handler([<<"benchmark">>], ?MODULE, undefined).

stop() ->
    application:stop(ecoap).

% resource operations
coap_discover(Prefix, _Args) ->
    [{absolute, Prefix, []}].

coap_get(_ChId, _Prefix, _Name, _Query) ->
    #coap_content{payload = <<"hello world">>}.

coap_post(_ChId, _Prefix, _Name, _Content) ->
    {error, 'MethodNotAllowed'}.

coap_put(_ChId, _Prefix, _Name, _Content) ->
    {error, 'MethodNotAllowed'}.

coap_delete(_ChId, _Prefix, _Name) ->
    {error, 'MethodNotAllowed'}.

coap_observe(_ChId, _Prefix, _Name, _Ack) ->
    {error, 'MethodNotAllowed'}.

coap_unobserve({state, _Prefix, _Name}) ->
    ok.

handle_info(_Message, State) -> {noreply, State}.
coap_ack(_Ref, State) -> {ok, State}.

