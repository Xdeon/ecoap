-module(benchmark).
-export([coap_discover/2, coap_get/5, coap_post/4, coap_put/4, coap_delete/4, coap_observe/4, coap_unobserve/1, handle_info/2, coap_ack/2]).
-export([start/0, stop/0]).
-export([fib/1]).

-include_lib("ecoap_common/include/coap_def.hrl").
-behaviour(coap_resource).

start() ->
    _ = application:stop(ecoap),
    {ok, _} = application:ensure_all_started(ecoap),
    ok = ecoap_registry:register_handler([<<"benchmark">>], ?MODULE, undefined),
    ok = ecoap_registry:register_handler([<<"fibonacci">>], ?MODULE, undefined),
    ok = ecoap_registry:register_handler([<<"helloWorld">>], ?MODULE, undefined),
    ok = ecoap_registry:register_handler([<<"shutdown">>], ?MODULE, undefined).

stop() ->
    application:stop(ecoap).

% resource operations
coap_discover(Prefix, _Args) ->
    [{absolute, Prefix, []}].

coap_get(_EpID, [<<"benchmark">>], _Name, _Query, _Request) ->
    #coap_content{payload = <<"hello world">>};
coap_get(_EpID, [<<"fibonacci">>], _Name, [], _Request) ->
    #coap_content{payload = <<"fibonacci(20) = ", (integer_to_binary(fib(20)))/binary>>};
coap_get(_EpID, [<<"fibonacci">>], _Name, [Query|_], _Request) ->
    Num = case re:run(Query, "^n=[0-9]+") of
        {match, [{Pos, Len}]} ->
            binary_to_integer(lists:nth(2, binary:split(binary:part(Query, Pos, Len), <<"=">>)));
        nomatch -> 
            20
    end,
    #coap_content{payload= <<"fibonacci(", (integer_to_binary(Num))/binary, ") = ", (integer_to_binary(fib(Num)))/binary>>};
coap_get(_EpID, [<<"helloWorld">>], _Name, _Query, _Request) ->
    #coap_content{payload = <<"Hello World!">>, format = 0};
coap_get(_EpID, [<<"shutdown">>], _Name, _Query, _Request) ->
    #coap_content{payload = <<"Send a POST request to this resource to shutdown the server">>};
coap_get(_EpID, _Prefix, _Name, _Query, _Request) ->
    {error, 'NotFound'}.

coap_post(_EpID, [<<"shutdown">>], _Name, _Request) ->
    _ = spawn(fun() -> io:format("Shutting down everything in 1 second~n"), timer:sleep(1000), benchmark:stop() end),
    {ok, 'Changed', #coap_content{payload = <<"Shutting down">>}};
coap_post(_EpID, _Prefix, _Name, _Request) ->
    {error, 'MethodNotAllowed'}.

coap_put(_EpID, _Prefix, _Name, _Request) ->
    {error, 'MethodNotAllowed'}.

coap_delete(_EpID, _Prefix, _Name, _Request) ->
    {error, 'MethodNotAllowed'}.

coap_observe(_EpID, _Prefix, _Name, _Request) ->
    {error, 'MethodNotAllowed'}.

coap_unobserve(_Obstate) ->
    ok.

handle_info(_Message, State) -> {noreply, State}.

coap_ack(_Ref, State) -> {ok, State}.

% we consider non-tail-recursive fibonacci function as a CPU intensive task
% thus when we do benchmarking, it should be tested combined with ordinary resource
% e.g. 1000 concurrent clients in total 
% with 100 requesting "fibonacci?n=30" resource (clients generating CPU load on server, a.k.a., intensive clients) 
% and 900 requesting "benchmark" resource (clients looking for non-CPU intensice resource, a.k.a., ordinary clients)
% we observe throughput & latency of the ordinary clients under this situation to test erlang's soft-realtime performance
% we also need to change PROCESSING_DELAY in coap_exchange.erl to a larger number, e.g. 100s, 
% to avoid triggering separate response

fib(0) -> 0;
fib(1) -> 1;
fib(N) -> fib(N - 1) + fib(N - 2).

% fibnacci function below should be used in any real world case, as it is far more efficient than the last one
% because of erlang's way of modeling numbers, it is easy to request for a quiet large fib number and the result
% can be automatically transferred in blocks if its size exceeds the required one

% fib(N) -> fib_iter(N, 0, 1).

% fib_iter(0, Result, _Next) -> 
%     Result;
% fib_iter(Iter, Result, Next) when Iter > 0 ->
%     fib_iter(Iter-1, Next, Result+Next).
