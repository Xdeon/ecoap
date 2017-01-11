-module(benchmark).
-export([coap_discover/2, coap_get/4, coap_post/4, coap_put/4, coap_delete/3, coap_observe/4, coap_unobserve/1, handle_info/2, coap_ack/2]).
-export([start/0, stop/0]).
-export([fib/1]).

-include("coap_def.hrl").
-behaviour(coap_resource).

start() ->
    _ = application:stop(ecoap),
    {ok, _} = application:ensure_all_started(ecoap),
    ok = ecoap_registry:register_handler([<<"benchmark">>], ?MODULE, undefined),
    ok = ecoap_registry:register_handler([<<"fibonacci">>], ?MODULE, undefined),
    ok = ecoap_registry:register_handler([<<"helloWorld">>], ?MODULE, undefined).

stop() ->
    application:stop(ecoap).

% resource operations
coap_discover(Prefix, _Args) ->
    [{absolute, Prefix, []}].

coap_get(_EpID, [<<"benchmark">>], _Name, _Query) ->
    #coap_content{payload = <<"hello world">>};

coap_get(_EpID, [<<"fibonacci">>], _Name, []) ->
    #coap_content{payload = <<"fibonacci(20) = ", (integer_to_binary(fib(20)))/binary>>};
coap_get(_EpID, [<<"fibonacci">>], _Name, [Query|_]) ->
    Num = case re:run(Query, "^n=[0-9]+") of
        {match, [{Pos, Len}]} ->
            binary_to_integer(lists:nth(2, binary:split(binary:part(Query, Pos, Len), <<"=">>)));
        nomatch -> 
            20
    end,
    #coap_content{payload= <<"fibonacci(", (integer_to_binary(Num))/binary, ") = ", (integer_to_binary(fib(Num)))/binary>>};

coap_get(_EpID, [<<"helloWorld">>], _Name, []) ->
    #coap_content{payload = <<"Hello World!">>, format = 0};

coap_get(_EpID, _Prefix, _Name, _Query) ->
    {error, 'NotFound'}.

coap_post(_EpID, _Prefix, _Name, _Content) ->
    {error, 'MethodNotAllowed'}.

coap_put(_EpID, _Prefix, _Name, _Content) ->
    {error, 'MethodNotAllowed'}.

coap_delete(_EpID, _Prefix, _Name) ->
    {error, 'MethodNotAllowed'}.

coap_observe(_EpID, _Prefix, _Name, _Ack) ->
    {error, 'MethodNotAllowed'}.

coap_unobserve({state, _Prefix, _Name}) ->
    ok.

handle_info(_Message, State) -> {noreply, State}.
coap_ack(_Ref, State) -> {ok, State}.

% fib(0) -> 0;
% fib(1) -> 1;
% fib(N) -> fib(N - 1) + fib(N - 2).

fib(N) -> fib_iter(N, 0, 1).

fib_iter(0, Result, _Next) -> 
    Result;
fib_iter(Iter, Result, Next) when Iter > 0 ->
    fib_iter(Iter-1, Next, Result+Next).
