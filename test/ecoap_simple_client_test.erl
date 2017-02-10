-module(ecoap_simple_client_test).
-include_lib("eunit/include/eunit.hrl").
-include_lib("ecoap_common/include/coap_def.hrl").

basic_test_() -> 
	[
		?_assertEqual({ok, 'Content', #coap_content{max_age = undefined, format = <<"text/plain">>, payload = <<"world">>}}, 
			ecoap_simple_client:request('GET', "coap://coap.me:5683/hello")),
		?_assertEqual({error, 'InternalServerError', #coap_content{max_age = undefined, format = <<"text/plain">>, payload = <<"Oops: broken">>}}, 
			ecoap_simple_client:request('GET', "coap://coap.me:5683/broken"))
	].