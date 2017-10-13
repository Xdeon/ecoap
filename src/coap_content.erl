-module(coap_content).
-export([new/0, new/1, new/2, set_payload/2, set_options/2, get_payload/1, get_options/1]).
-export([get_content/1]).

-include("coap_content.hrl").

-type coap_content() :: #coap_content{}.

-export_type([coap_content/0]).

new() -> #coap_content{}.

new(Payload) -> #coap_content{payload=Payload}.

new(Payload, Options) -> #coap_content{payload=Payload, options=Options}.

set_payload(Payload, Content) -> Content#coap_content{payload=Payload}.

set_options(Options, Content) -> Content#coap_content{options=Options}.

get_payload(#coap_content{payload=Payload}) -> Payload.

get_options(#coap_content{options=Options}) -> Options.

get_content(Request) ->
    #coap_content{payload=coap_message:get_payload(Request), options=filter_options(coap_message:get_options(Request))}.

filter_options(Options) ->
    UnusedOptions = ['Uri-Path', 'Uri-Query', 'Block1', 'Block2', 'If-Match', 'If-None-Match'],
    coap_message:remove_options(UnusedOptions, Options).
