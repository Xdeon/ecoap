-module(coap_content).
-export([new/0, new/1, new/2, set_payload/2, get_payload/1, set_options/2, get_options/1, set_option/3, get_option/2, get_option/3]).
-export([get_content/1]).

-include("coap_content.hrl").

-type coap_content() :: #coap_content{}.

-export_type([coap_content/0]).

-spec new() -> coap_content().
new() -> #coap_content{}.

-spec new(binary()) -> coap_content().
new(Payload) -> #coap_content{payload=Payload}.

-spec new(binary(), coap_message:optionset()) -> coap_content().
new(Payload, Options) -> #coap_content{payload=Payload, options=Options}.

-spec set_payload(binary(), coap_content()) -> coap_content().
set_payload(Payload, Content) -> Content#coap_content{payload=Payload}.

-spec get_payload(coap_content()) -> binary().
get_payload(#coap_content{payload=Payload}) -> Payload.

-spec set_options(coap_message:optionset(), coap_content()) -> coap_content().
set_options(Options, Content) -> Content#coap_content{options=Options}.

-spec get_options(coap_content()) -> coap_message:optionset().
get_options(#coap_content{options=Options}) -> Options.

-spec set_option(coap_message:coap_option(), term(), coap_content()) -> coap_content().
set_option(Option, Value, Content=#coap_content{options=Options}) -> Content#coap_content{options=Options#{Option=>Value}}.

-spec get_option(coap_message:coap_option(), coap_content()) -> term().
get_option(Option, Content) -> get_option(Option, Content, undefined).

-spec get_option(coap_message:coap_option(), coap_content(), term()) -> term().
get_option(Option, #coap_content{options=Options}, Default) -> maps:get(Option, Options, Default).

-spec get_content(coap_message:coap_message()) -> coap_content().
get_content(Request) ->
    #coap_content{payload=coap_message:get_payload(Request), options=filter_options(coap_message:get_options(Request))}.

-spec filter_options(coap_message:optionset()) -> coap_message:optionset().
filter_options(Options) ->
    UnusedOptions = ['Uri-Path', 'Uri-Query', 'Block1', 'Block2', 'If-Match', 'If-None-Match', 'Observe'],
    coap_message:remove_options(UnusedOptions, Options).
