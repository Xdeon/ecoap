-module(coap_content).
-export([new/0, set_payload/2, set_options/2, get_payload/1, get_options/1]).
-export([get_content/1]).
% -export([normalize/1]).

-type coap_content() ::
    #{
        payload := binary(),
        options := coap_message:optionset()
    }.

-export_type([coap_content/0]).

-spec new() -> coap_content().
new() ->
    #{payload=> <<>>, options=>#{}}.

-spec set_payload(binary(), map()) -> coap_content().
set_payload(Payload, Content) ->
    maps:update(payload, Payload, Content).

-spec set_options(coap_message:optionset(), coap_content()) -> coap_content().
set_options(Options, Content) ->
    maps:update(options, Options, Content).

-spec get_payload(coap_content()) -> binary().
get_payload(Content) ->
    maps:get(payload, Content, <<>>).

-spec get_options(coap_content()) -> coap_message:optionset().
get_options(Content) ->
    maps:get(options, Content, #{}).

% -spec normalize(map()) -> coap_content().
% normalize(Content=#{payload:=_, options:=_}) -> Content;
% normalize(Content=#{payload:=_}) -> Content#{options=>#{}};
% normalize(Content=#{options:=_}) -> Content#{payload=> <<>>};
% normalize(_) -> new().

-spec get_content(coap_message:coap_message()) -> coap_content().
get_content(Message) ->
    #{payload=>coap_message:get_payload(Message), options=>filter_options(coap_message:get_options(Message))}.

% -record(coap_content, {
%     payload = <<>> :: binary(),
%     options = #{} :: coap_message:optionset()
%     }).

% new() -> #coap_content{}.

% set_payload(Payload, Content) -> Content#coap_content{payload=Payload}.

% set_options(Options, Content) -> Content#coap_content{options=Options}.

% get_payload(#coap_content{payload=Payload}) -> Payload.

% get_options(#coap_content{options=Options}) -> Options.

% get_content(Request) ->
%     #coap_content{payload=coap_message:get_payload(Request), options=filter_options(coap_message:get_options(Request))}.

filter_options(Options) ->
    UnusedOptions = ['Uri-Path', 'Uri-Query', 'Block1', 'Block2', 'If-Match', 'If-None-Match'],
    coap_message:remove_options(UnusedOptions, Options).
