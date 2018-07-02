-module(ecoap_default).
-export([config/0, merge_config/1, handler_config/1, default_max_block_size/0]).

-type config() :: map().
-export_type([config/0]).

config() ->
	#{
		exchange_lifetime => 247000,
		non_lifetime => 145000,
		processing_delay => 1000,	% standard allows 2000
		max_retransmit => 4,
		ack_random_factor => 1000, 	% ACK_TIMEOUT*0.5
		ack_timeout => 2000,
		max_block_size => 1024,
		max_body_size => 8192
	}.

merge_config(CustomConfig) ->
    maps:update_with(non_lifetime, fun native_time/1, 
    	maps:update_with(exchange_lifetime,  fun native_time/1, 
    		maps:merge(config(), CustomConfig))).

native_time(Time) ->
    erlang:convert_time_unit(Time, millisecond, native).

handler_config(Config) ->
	maps:without([sock, sock_module, ep_id, handler_regs], Config).

default_max_block_size() -> 1024.