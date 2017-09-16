-module(ecoap_simple_client_test).
-include_lib("eunit/include/eunit.hrl").
-include("ecoap.hrl").

basic_test_() -> 
	[
		?_assertEqual(ok, ecoap_simple_client:ping("coap://coap.me:5683")),
		?_assertEqual({ok, 'Content', <<"world">>, #{'Content-Format' => <<"text/plain">>}}, 
			ecoap_simple_client:request('GET', "coap://coap.me:5683/hello")),
		?_assertEqual({error, 'InternalServerError', <<"Oops: broken">>, #{'Content-Format' => <<"text/plain">>}}, 
			ecoap_simple_client:request('GET', "coap://coap.me:5683/broken")),
		?_assertEqual({ok, 'Created', <<>>, #{'Location-Path' => [<<"large-create">>]}},
            ecoap_simple_client:request('POST', "coap://coap.me:5683/large-create", <<"Test">>)),
        ?_assertEqual({ok, 'Changed', <<>>, #{}}, 
            ecoap_simple_client:request('PUT', "coap://coap.me:5683/large-update", <<"Test">>)),
        ?_assertEqual({ok, 'Deleted', <<"DELETE OK">>, #{'Content-Format' = <<"text/plain">>}}, 
            ecoap_simple_client:request('DELETE', "coap://coap.me:5683/sink"))
	].