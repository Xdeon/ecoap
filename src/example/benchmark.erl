-module(benchmark).
-export([coap_discover/1, coap_get/4, coap_post/4]).
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
    {ok, _} = ecoap:start_udp(benchmark_udp, [{port, 5683}, {recbuf, 1048576}, {sndbuf, 1048576}],
        #{routes => Routes, protocol_config => #{exchange_lifetime => 1500}}),
    {ok, _} = ecoap:start_dtls(benchmark_dtls, [
        {port, 5684}, 
        {recbuf, 1048576}, 
        {sndbuf, 1048576}, 
        {keyfile, "./cert/server.key"}, 
        {certfile, "./cert/server.crt"}, 
        {cacertfile, "./cert/cowboy-ca.crt"}
    ], #{routes => Routes
        % protocol_config => #{exchange_lifetime => 1500},
    }).

stop() ->
    application:stop(ecoap).

% resource operations
coap_discover(Prefix) ->
    [{absolute, Prefix, []}].

coap_get(_EpID, [<<"benchmark">>], _Suffix, _Request) ->
    {ok, coap_content:new(<<"hello world">>)};

coap_get(_EpID, [<<"fibonacci">>], _Suffix, Request) ->
    Query = ecoap_request:query(Request),
    % could use cow_lib to parse query 
    Num = lists:foldl(fun(Q, Acc) -> 
            case uri_string:dissect_query(Q) of
                [{<<"n">>, N}] -> binary_to_integer(N);
                _ -> Acc 
            end 
        end, 20, Query),
    Payload = <<"fibonacci(", (integer_to_binary(Num))/binary, ") = ", (integer_to_binary(fib((Num))))/binary>>,
    {ok, coap_content:new(Payload, #{'Content-Format' => <<"text/plain">>})};

coap_get(_EpID, [<<"helloWorld">>], _Suffix, _Request) ->
    {ok, coap_content:new(<<"Hello World">>, #{'Content-Format' => <<"text/plain">>})};

coap_get(_EpID, [<<"shutdown">>], _Suffix, _Request) ->
    {ok, coap_content:new(<<"Send a POST request to this resource to shutdown the server">>)};

coap_get(_EpID, _Prefix, _Suffix, _Request) ->
    {error, 'NotFound'}.

coap_post(_EpID, [<<"shutdown">>], _Suffix, _Request) ->
    _ = spawn(fun() -> io:format("Shutting down everything in 1 second~n"), timer:sleep(1000), benchmark:stop() end),
    {ok, 'Changed', coap_content:new(<<"Shutting down">>)};

coap_post(_EpID, _Prefix, _Suffix, _Request) ->
    {error, 'MethodNotAllowed'}.

% coap_put(_EpID, _Prefix, _Suffix, _Request) ->
%     {error, 'MethodNotAllowed'}.

% coap_delete(_EpID, _Prefix, _Suffix, _Request) ->
%     {error, 'MethodNotAllowed'}.

% coap_observe(_EpID, _Prefix, _Suffix, _Request) ->
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
