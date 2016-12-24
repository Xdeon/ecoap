-module(ecoap_client_test).
-include_lib("eunit/include/eunit.hrl").
-include_lib("ecoap/include/coap_def.hrl").

basic_test_() ->
    {setup,
        fun() ->
            {ok, Pid} = ecoap_client:start_link(),
            Pid
        end,
        fun(Pid) ->
            ecoap_client:close(Pid)
        end,
        fun basic/1}.

basic(Pid) ->
	[
		?_assertEqual({ok, 'Content', #coap_content{max_age = undefined, format = <<"text/plain">>, payload = <<"world">>}}, 
			ecoap_client:request(Pid, 'GET', "coap://coap.me:5683/hello")),
		?_assertEqual({error, 'InternalServerError', #coap_content{max_age = undefined, format = <<"text/plain">>, payload = <<"Oops: broken">>}}, 
			ecoap_client:request(Pid, 'GET', "coap://coap.me:5683/broken"))
	].