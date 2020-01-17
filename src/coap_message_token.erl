-module(coap_message_token).
-export([generate_token/1]).

-spec generate_token(non_neg_integer()) -> coap_message:token().
generate_token(TKL) ->
    crypto:strong_rand_bytes(TKL).