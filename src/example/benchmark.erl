-module(benchmark).
-export([coap_discover/1, coap_get/5, coap_post/4]).
-export([start/0, stop/0]).
-export([fib/1]).

-behaviour(ecoap_handler).

start() ->
    _ = application:stop(ecoap),
    {ok, _} = application:ensure_all_started(ecoap),
    Routes = [
            {[<<"benchmark">>], ?MODULE},
            {[<<"fibonacci">>], ?MODULE},
            {[<<"helloWorld">>], ?MODULE},
            {[<<"shutdown">>], ?MODULE}
    ],
    ecoap:start_udp(benchmark_server, [{recbuf, 1048576}, {sndbuf, 1048576}], #{routes => Routes}).
    
stop() ->
    application:stop(ecoap).

% resource operations
coap_discover(Prefix) ->
    [{absolute, Prefix, []}].

coap_get(_EpID, [<<"benchmark">>], _Name, _Query, _Request) ->
    {ok, coap_content:new(<<"hello world">>)};

coap_get(_EpID, [<<"fibonacci">>], _Name, [], _Request) ->
    Payload = <<"fibonacci(20) = ", (integer_to_binary(fib(20)))/binary>>,
    {ok, coap_content:new(Payload, #{'Content-Format' => <<"text/plain">>})};

coap_get(_EpID, [<<"fibonacci">>], _Name, [Query|_], _Request) ->
    Num = case re:run(Query, "^n=[0-9]+$") of
        {match, _} ->
            lists:nth(2, binary:split(Query, <<$=>>));
        nomatch -> 
            <<"20">>
    end,
    Payload = <<"fibonacci(", Num/binary, ") = ", (integer_to_binary(fib(binary_to_integer(Num))))/binary>>,
    {ok, coap_content:new(Payload, #{'Content-Format' => <<"text/plain">>})};

coap_get(_EpID, [<<"helloWorld">>], _Name, _Query, _Request) ->
    {ok, coap_content:new(<<"Hello World">>, #{'Content-Format' => <<"text/plain">>})};

coap_get(_EpID, [<<"shutdown">>], _Name, _Query, _Request) ->
    {ok, coap_content:new(<<"Send a POST request to this resource to shutdown the server">>)};

coap_get(_EpID, _Prefix, _Name, _Query, _Request) ->
    {error, 'NotFound'}.

coap_post(_EpID, [<<"shutdown">>], _Name, _Request) ->
    _ = spawn(fun() -> io:format("Shutting down everything in 1 second~n"), timer:sleep(1000), benchmark:stop() end),
    {ok, 'Changed', coap_content:new(<<"Shutting down">>)};

coap_post(_EpID, _Prefix, _Name, _Request) ->
    {error, 'MethodNotAllowed'}.

% coap_put(_EpID, _Prefix, _Name, _Request) ->
%     {error, 'MethodNotAllowed'}.

% coap_delete(_EpID, _Prefix, _Name, _Request) ->
%     {error, 'MethodNotAllowed'}.

% coap_observe(_EpID, _Prefix, _Name, _Request) ->
%     {error, 'MethodNotAllowed'}.

% coap_unobserve(_Obstate) ->
%     ok.

% handle_info(_Info, _ObsReq, State) -> {noreply, State}.

% coap_ack(_Ref, State) -> {ok, State}.

% we consider non-tail-recursive fibonacci function as a CPU intensive task
% thus when we do benchmarking, it should be tested combined with ordinary resource
% e.g. 1000 concurrent clients in total 
% with 100 requesting "fibonacci?n=30" resource (clients generating CPU load on server, a.k.a., intensive clients) 
% and 900 requesting "benchmark" resource (clients looking for non-CPU intensice resource, a.k.a., ordinary clients)
% we observe throughput & latency of the ordinary clients under this situation to test erlang's soft-realtime performance
% we also need to change PROCESSING_DELAY in ecoap_exchange.erl to a larger number, e.g. 100s, 
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
