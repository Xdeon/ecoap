-module(ecoap_message_token).
-export([generate_token/0, generate_token/1]).

-define(TOKEN_LENGTH, 4). % shall be at least 32 random bits

-spec generate_token() -> binary().
generate_token() -> generate_token(?TOKEN_LENGTH).

-spec generate_token(non_neg_integer()) -> binary().
generate_token(TKL) ->
    crypto:strong_rand_bytes(TKL).