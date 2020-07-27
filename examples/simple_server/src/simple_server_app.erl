-module(simple_server_app).
-behaviour(application).

-export([start/2]).
-export([stop/1]).

start(_Type, _Args) ->
	ensure_db(resources),
	ecoap:start_udp(simple_server, [{port, application:get_env(simple_server, port, 5683)}],
        #{routes => [{[<<"*">>], simple}], protocol_config => #{max_block_size => 64}}),
	simple_server_sup:start_link().

stop(_State) ->
	ok = ecoap:stop_udp(simple_server).

ensure_db(Name) ->
	case table_exist(Name) of
		true -> 
			{atomic, ok} = mnesia:delete_table(Name),
			{atomic, ok} = mnesia:create_table(Name, []);
		false -> 
			{atomic, ok} = mnesia:create_table(Name, [])
	end,
	ok = mnesia:wait_for_tables([Name], 3000).

table_exist(Name) ->
	lists:member(Name, mnesia:system_info(tables)).