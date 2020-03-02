-module(benchmark).
-behaviour(ecoap_handler).

-export([coap_discover/1, coap_get/4, coap_post/4]).
-export([start/0, start_dtls/1, stop/0, stop_dtls/0]).
-export([start_dtls_client/3]).
-export([fib/1]).

start() ->
    {ok, _} = application:ensure_all_started(ecoap),
    ecoap:start_udp(benchmark_udp, 
        [
            {ip, {0,0,0,0}}, 
            {port, 5683}, 
            {recbuf, 1048576}, 
            {sndbuf, 1048576}
        ],
        #{routes => routes(), protocol_config => #{exchange_lifetime => 1500}}).

start_dtls(psk) ->
    {ok, _} = application:ensure_all_started(ecoap),
    ecoap:start_dtls(benchmark_dtls, 
    [
        {ip, {0,0,0,0}},
        {port, 5684}, 
        {recbuf, 1048576}, 
        {sndbuf, 1048576}
    ] ++ psk_options("plz_use_ecoap_id_a", 
                    fun server_user_lookup/3, 
                    #{<<"ecoap_id_a">> => <<"ecoap_pwd_a">>, 
                    <<"ecoap_id_b">> => <<"ecoap_pwd_b">>}), 
    #{routes => routes()});
start_dtls(cert) ->
    {ok, _} = application:ensure_all_started(ecoap),
    ecoap:start_dtls(benchmark_dtls, 
    [
        {ip, {0,0,0,0}},
        {port, 5684}, 
        {recbuf, 1048576}, 
        {sndbuf, 1048576},
        {keyfile, "./cert/server.key"}, 
        {certfile, "./cert/server.crt"}, 
        {cacertfile, "./cert/cowboy-ca.crt"},
        {ciphers, ssl:cipher_suites(all, 'dtlsv1.2') ++ 
                    ssl:cipher_suites(anonymous, 'dtlsv1.2') ++ 
                    ssl:cipher_suites(anonymous, 'tlsv1.2')}
    ], 
    #{routes => routes()}).

stop() ->
    _ = ecoap:stop_udp(benchmark_udp),
    application:stop(ecoap).

stop_dtls() ->
    _ = ecoap:stop_dtls(benchmark_dtls),
    application:stop(ecoap).

% client sample code for dtls connection
start_dtls_client(Host, Port, psk) ->
    _ = application:ensure_all_started(ssl),
    ecoap_client:open(Host, Port, 
        #{transport => dtls,
        transport_opts => psk_options("ecoap_id_b", 
                                fun client_user_lookup/3, 
                                #{<<"ecoap_id_a">> => <<"ecoap_pwd_a">>, 
                                <<"ecoap_id_b">> => <<"ecoap_pwd_b">>})});
start_dtls_client(Host, Port, cert) ->
    _ = application:ensure_all_started(ssl),
    ecoap_client:open(Host, Port, 
        #{transport => dtls,
        transport_opts => [{ciphers, ssl:cipher_suites(all, 'dtlsv1.2') ++ 
                                    ssl:cipher_suites(anonymous, 'dtlsv1.2') ++ 
                                    ssl:cipher_suites(anonymous, 'tlsv1.2')}]}).

% utility functions
routes() ->
    [
            {[<<"benchmark">>], ?MODULE},
            {[<<"fibonacci">>], ?MODULE},
            {[<<"helloWorld">>], ?MODULE},
            {[<<"shutdown">>], ?MODULE}
    ].

psk_options(Identity, LookupFun, UserState) -> 
    [
     {verify, verify_none},
     {protocol, dtls},
     {versions, [dtlsv1, 'dtlsv1.2']},
     {ciphers, psk_ciphers()},
     {psk_identity, Identity},
     {user_lookup_fun,
       {LookupFun, UserState}}
].

psk_ciphers() ->
    ssl:filter_cipher_suites(
        ssl:cipher_suites(anonymous, 'dtlsv1.2'), [{cipher, fun(aes_128_ccm_8) -> true; (_) -> false end}]).

server_user_lookup(psk, ClientPSKID, _UserState = PSKs) ->
    ServerPickedPSK = maps:get(<<"ecoap_id_a">>, PSKs),
    io:format("ClientPSKID: ~p, ServerPickedPSK: ~p~n", [ClientPSKID, ServerPickedPSK]),
    {ok, ServerPickedPSK}.

client_user_lookup(psk, ServerHint, _UserState = PSKs) ->
    ServerPskId = server_suggested_psk_id(ServerHint),
    ClientPsk = maps:get(ServerPskId, PSKs),
    io:format("ServerHint:~p, ServerSuggestedPSKID:~p, ClientPickedPSK: ~p~n",
              [ServerHint, ServerPskId, ClientPsk]),
    {ok, ClientPsk}.

server_suggested_psk_id(ServerHint) ->
    [_, Psk] = binary:split(ServerHint, <<"plz_use_">>),
    Psk.

% resource operations
coap_discover(Prefix) ->
    [{absolute, Prefix, []}].

coap_get(_EpID, [<<"benchmark">>], _Suffix, _Request) ->
    {ok, coap_content:new(<<"hello world">>)};

coap_get(_EpID, [<<"fibonacci">>], _Suffix, Request) ->
    Num = get_fib_arg(ecoap_request:query(Request), 20),
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

% could use cow_lib to parse query 
get_fib_arg(Query, Default) ->   
    lists:foldl(fun(Q, Acc) -> 
            case uri_string:dissect_query(Q) of
                [{<<"n">>, N}] -> 
                    try binary_to_integer(N) 
                    catch _:_ -> Acc
                    end;
                _ -> Acc 
            end 
    end, Default, Query).

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
