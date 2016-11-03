-module(coap_handler).
-behaviour(gen_server).

%% API.
-export([start_link/2]).

%% gen_server.
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-record(state, {
	endpoint_pid,
	prefix, 
	module, 
	args, 
	insegs, 
	last_response, 
	observer, 
	obseq, 
	obstate, 
	timer}).

-include("coap_def.hrl").

%% API.

-spec start_link(pid(), list(binary())) -> {ok, pid()}.
start_link(EndpointPid, Uri) ->
	gen_server:start_link(?MODULE, [EndpointPid, Uri], []).

%% gen_server.

init([EndpointPid, Uri]) ->
    % the receiver will be determined based on the URI
    case ecoap_registry:match_handler(Uri) of
        {Prefix, Module, Args} ->
            % EndpointPid ! {handler_started, self()},
            {ok, #state{endpoint_pid=EndpointPid, prefix=Prefix, module=Module, args=Args,
                insegs=orddict:new(), obseq=0}};
        undefined ->
            {stop, not_found}
    end.

handle_call(_Request, _From, State) ->
	{reply, ignored, State}.

handle_cast(_Msg, State) ->
	{noreply, State}.

handle_info({coap_request, EpID, _EndpointPid, _Receiver=undefined, Request}, State) ->
	handle(EpID, Request, State);

handle_info(_Info, State) ->
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%% Internal
handle(_EpID, Request, State=#state{endpoint_pid=EndpointPid, prefix=Prefix}) ->
	#coap_message{id=MsgId, token=Token, type=Type, options=Options} = Request,
    _ = case proplists:get_value('Observe', Options, []) of
		[] -> ok;
		_Else -> EndpointPid ! {obs_handler_started, self()}
	end,
	{ok, _} = case Type of
		'CON' ->
			Msg = #coap_message{type = 'CON', code = {ok, 'CONTENT'}, id = MsgId, token = Token, options = [{'Content-Format', <<"text/plain">>}], payload = list_to_binary(Prefix)},
			coap_endpoint:send(EndpointPid, Msg);
		'NON' ->
			Msg = #coap_message{type = 'NON', code = {ok, 'CONTENT'}, id = MsgId, token = Token, options = [{'Content-Format', <<"text/plain">>}], payload = list_to_binary(Prefix)},
			coap_endpoint:send(EndpointPid, Msg)
	end,
	{noreply, State}.


