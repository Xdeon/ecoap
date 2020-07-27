-module(benchmark_dtls_app).
-behaviour(application).

-export([start_dtls/1, start/0, start/2]).
-export([stop/0, stop/1]).
-export([start_dtls_client/3]).

start() ->
    {ok, _Started} = application:ensure_all_started(benchmark_dtls).

stop() ->
	application:stop(benchmark_dtls).

start(_Type, _Args) ->
	Sec = application:get_env(benchmark_dtls, security, psk),
	{ok, _} = start_dtls(Sec),
	benchmark_dtls_sup:start_link().

stop(_State) ->
	ok = ecoap:stop_dtls(benchmark_dtls).

start_dtls(psk) ->
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

routes() ->
    [
            {[<<"benchmark">>], benchmark},
            {[<<"fibonacci">>], benchmark},
            {[<<"helloWorld">>], benchmark},
            {[<<"shutdown">>], benchmark}
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