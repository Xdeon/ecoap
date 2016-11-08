-module(test_resource).
-export([coap_discover/2, coap_get/4, coap_post/4, coap_put/4, coap_delete/3, coap_observe/4, coap_unobserve/1, handle_info/2, coap_ack/2]).

-include("coap_def.hrl").
-behaviour(coap_resource).

coap_discover(Prefix, _Args) ->
    io:format("discover ~p~n", [Prefix]),
    [{absolute, Prefix, [{obs, <<"true">>}, {rt, <<"observe">>}]}].

coap_get(_ChId, Prefix, Name, Query) ->
    io:format("get ~p ~p ~p~n", [Prefix, Name, Query]),
    #coap_content{payload = <<"hello world">>, max_age=undefined}.

coap_post(_ChId, Prefix, Name, Content) ->
    io:format("post ~p ~p ~p~n", [Prefix, Name, Content]),
    {error, 'METHOD_NOT_ALLOWED'}.

coap_put(_ChId, Prefix, Name, Content) ->
    io:format("put ~p ~p ~p~n", [Prefix, Name, Content]),
    ok.

coap_delete(_ChId, Prefix, Name) ->
    io:format("delete ~p ~p~n", [Prefix, Name]),
    ok.

coap_observe(_ChId, Prefix, Name, _Ack) ->
    io:format("observe ~p ~p~n", [Prefix, Name]),
    {ok, _Obstate = {state, Prefix, Name}}.

coap_unobserve(_Obstate = {state, Prefix, Name}) ->
    io:format("unobserve ~p ~p~n", [Prefix, Name]),
    ok.

handle_info(_Info, State) ->
	{notify, make_ref(), #coap_content{payload=integer_to_binary(erlang:monotonic_time())}, State}.

coap_ack(_Ref, State) -> {ok, State}.