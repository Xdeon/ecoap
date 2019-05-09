% PLACE FOR LICENSE

Nonterminals LINKLIST LINK URI PARAMS PARAM.
Terminals '<' '/' '>' ';' ',' '=' segment string.
Rootsymbol LINKLIST.

LINKLIST -> LINK : ['$1'].
LINKLIST -> LINK ',' LINKLIST : ['$1'|'$3'].

LINK -> '<' '/' URI '>' PARAMS : {absolute, '$3', '$5'}.
LINK -> '<' URI '>' PARAMS : {rootless, '$2', '$4'}.

URI -> '$empty' : [].
URI  -> segment : [strval('$1')].
URI  -> segment '/' URI : [strval('$1')|'$3'].

PARAMS -> ';' PARAM PARAMS: ['$2'|'$3'].
PARAMS -> '$empty' : [].

PARAM -> segment : {atomval('$1'), true}.
PARAM -> segment '=' segment : {atomval('$1'), strval('$1', '$3')}.
PARAM -> segment '=' string : {atomval('$1'), strval('$1', '$3')}.

Erlang code.

atomval({_, _, Val}) -> erlang:list_to_atom(Val).

strval({_, _, Val}) -> erlang:list_to_binary(Val).

% shortcut for CoRE link/LwM2M defined attribute
strval({_, _, "title"}, {_, _, Val}) -> 
	erlang:list_to_binary(Val);
strval({_, _, "ver"}, {_, _, Val}) ->
	erlang:list_to_binary(Val);
strval({_, _, "ct"}, {_, _, Val}) ->
	maybe_multiple_strvals(Val, fun erlang:list_to_integer/1);
strval({_, _, Attr}, {_, _, Val}) when Attr =:= "sz"; Attr =:= "dim"; Attr =:= "pmin"; Attr =:= "pmax" ->
	erlang:list_to_integer(Val);
strval({_, _, Attr}, {_, _, Val}) when Attr =:= "gt"; Attr =:= "lt"; Attr =:= "st" ->
	try erlang:list_to_float(Val)
	catch error:badarg -> erlang:list_to_integer(Val)
	end;
% unknown attribute
strval(_, {_, _, Val}) ->
	maybe_multiple_strvals(Val, fun convert/1).

convert(Val) ->
	case catch {ok, erlang:list_to_integer(Val)} of
		{ok, Res} -> Res;
		_ ->
			case catch {ok, erlang:list_to_float(Val)} of
				{ok, Res} -> Res;
				_ ->
					erlang:list_to_binary(Val)
			end
	end.

maybe_multiple_strvals(Val, TransferFun) ->
	case string:lexemes(Val, " ") of
		[Val] -> TransferFun(Val);
		[_|_] = Splited -> [TransferFun(Elem) || Elem <- Splited]
	end.