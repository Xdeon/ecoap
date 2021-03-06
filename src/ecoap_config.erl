-module(ecoap_config).
-export([default_protocol_config/0, merge_protocol_config/1, handler_config/1]).

-type protocol_config() :: #{
	token_length := 0..8, 
	exchange_lifetime := non_neg_integer(),
	non_lifetime := non_neg_integer(),
	processing_delay := non_neg_integer(),
	max_retransmit := non_neg_integer(),
	ack_random_factor := non_neg_integer(),
	ack_timeout := non_neg_integer(),
	max_block_size := non_neg_integer(),
	max_body_size := non_neg_integer(),
	endpoint_pid => pid()
}.

-type handler_config() :: #{
	endpoint_pid := pid(),
	exchange_lifetime := non_neg_integer(),
	max_body_size := non_neg_integer(),
	max_body_size := non_neg_integer()
}.

-export_type([protocol_config/0, handler_config/0]).

-spec default_protocol_config() -> protocol_config().
default_protocol_config() ->
	#{
		token_length => 4,  		% shall be at least 32 random bits
		exchange_lifetime => 247000,
		non_lifetime => 145000,
		processing_delay => 1000,	% standard allows 2000
		max_retransmit => 4,
		ack_random_factor => 1000, 	% ACK_TIMEOUT*0.5
		ack_timeout => 2000,
		max_block_size => 1024,
		max_body_size => 8192
	}.

-spec merge_protocol_config(map()) -> protocol_config().
merge_protocol_config(CustomConfig) ->
	Config = maps:merge(default_protocol_config(), CustomConfig),
	#{non_lifetime:=Val1, exchange_lifetime:=Val2} = Config,
	Config#{non_lifetime:=native_time(Val1), exchange_lifetime:=native_time(Val2)}.

-spec handler_config(protocol_config()) -> handler_config().
handler_config(Config) ->
	maps:with([endpoint_pid, exchange_lifetime, max_body_size, max_block_size], Config).

native_time(Time) ->
    erlang:convert_time_unit(Time, millisecond, native).