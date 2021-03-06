-module(ecoap_simple_client_test).
-include_lib("eunit/include/eunit.hrl").
-include_lib("src/ecoap_content.hrl").

basic_test_() -> 
	[
		?_assertEqual(ok, ecoap_simple_client:ping("coap://coap.me:5683")),
		?_assertEqual({ok, 'Content', #ecoap_content{payload= <<"world">>, options=#{'Content-Format' => <<"text/plain">>}}}, 
			ecoap_simple_client:request('GET', "coap://coap.me:5683/hello")),
		?_assertEqual({error, 'InternalServerError', #ecoap_content{payload= <<"Oops: broken">>, options=#{'Content-Format' => <<"text/plain">>}}}, 
			ecoap_simple_client:request('GET', "coap://coap.me:5683/broken")),
		?_assertEqual({ok, 'Created', #ecoap_content{options=#{'Location-Path' => [<<"large-create">>]}}},
            ecoap_simple_client:request('POST', "coap://coap.me:5683/large-create", <<"Test">>)),
        ?_assertEqual({ok, 'Changed', #ecoap_content{}}, 
            ecoap_simple_client:request('PUT', "coap://coap.me:5683/large-update", <<"Test">>)),
        ?_assertEqual({ok, 'Deleted', #ecoap_content{payload= <<"DELETE OK">>, options=#{'Content-Format' => <<"text/plain">>}}}, 
            ecoap_simple_client:request('DELETE', "coap://coap.me:5683/sink"))
	].