-module(ecoap_content).
-export([new/0, new/1, new/2, set_payload/2, get_payload/1, set_options/2, get_options/1, set_option/3, get_option/2, get_option/3]).
-export([get_content/1]).

-include("ecoap_content.hrl").

-type ecoap_content() :: #ecoap_content{}.

-export_type([ecoap_content/0]).

-spec new() -> ecoap_content().
new() -> #ecoap_content{}.

-spec new(binary()) -> ecoap_content().
new(Payload) -> #ecoap_content{payload=Payload}.

-spec new(binary(), ecoap_message:optionset()) -> ecoap_content().
new(Payload, Options) -> #ecoap_content{payload=Payload, options=Options}.

-spec set_payload(binary(), ecoap_content()) -> ecoap_content().
set_payload(Payload, Content) -> Content#ecoap_content{payload=Payload}.

-spec get_payload(ecoap_content()) -> binary().
get_payload(#ecoap_content{payload=Payload}) -> Payload.

-spec set_options(ecoap_message:optionset(), ecoap_content()) -> ecoap_content().
set_options(Options, Content) -> Content#ecoap_content{options=Options}.

-spec get_options(ecoap_content()) -> ecoap_message:optionset().
get_options(#ecoap_content{options=Options}) -> Options.

-spec set_option(ecoap_message:coap_option(), term(), ecoap_content()) -> ecoap_content().
set_option(Option, Value, Content=#ecoap_content{options=Options}) -> Content#ecoap_content{options=Options#{Option=>Value}}.

-spec get_option(ecoap_message:coap_option(), ecoap_content()) -> term().
get_option(Option, Content) -> get_option(Option, Content, undefined).

-spec get_option(ecoap_message:coap_option(), ecoap_content(), term()) -> term().
get_option(Option, #ecoap_content{options=Options}, Default) -> maps:get(Option, Options, Default).

-spec get_content(ecoap_message:ecoap_message()) -> ecoap_content().
get_content(Request) ->
    #ecoap_content{payload=ecoap_message:get_payload(Request), options=filter_options(ecoap_message:get_options(Request))}.

-spec filter_options(ecoap_message:optionset()) -> ecoap_message:optionset().
filter_options(Options) ->
    UnusedOptions = ['Uri-Path', 'Uri-Query', 'Block1', 'Block2', 'If-Match', 'If-None-Match', 'Observe'],
    ecoap_message:remove_options(UnusedOptions, Options).
