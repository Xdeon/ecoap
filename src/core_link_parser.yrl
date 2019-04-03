% PLACE FOR LICENSE

Nonterminals LINKLIST LINK URI PARAMS PARAM.
Terminals '<' '/' '>' ';' ',' '=' segment string.
Rootsymbol LINKLIST.

LINKLIST -> LINK : ['$1'].
LINKLIST -> LINK ',' LINKLIST : ['$1'|'$3'].

LINK -> '<' '/' URI '>' PARAMS : {absolute, '$3', '$5'}.
LINK -> '<' URI '>' PARAMS : {rootless, '$2', '$4'}.

URI  -> segment : [strval('$1')].
URI  -> segment '/' URI : [strval('$1')|'$3'].

PARAMS -> ';' PARAM PARAMS: ['$2'|'$3'].
PARAMS -> '$empty' : [].

PARAM -> segment : {atomval('$1'), true}.
PARAM -> segment '=' segment : {atomval('$1'), strval('$1', '$3')}.
PARAM -> segment '=' string : {atomval('$1'), strval('$1', '$3')}.

Erlang code.

atomval({_, _, Val}) -> list_to_atom(Val).

strval({_, _, Val}) -> list_to_binary(Val).

strval({_, _, "title"}, {_, _, Val}) -> 
	list_to_binary(Val);
strval({_, _, "sz"}, {_, _, Val}) -> 
%	try list_to_integer(Val)
%	catch error:badarg -> list_to_binary(Val)
%	end;
	list_to_integer(Val);
strval({_, _, "ct"}, {_, _, Val}) -> 
	maybe_multiple_strvals(Val, fun list_to_integer/1);
strval(_, {_, _, Val}) -> 
	maybe_multiple_strvals(Val, fun list_to_binary/1).

maybe_multiple_strvals(Val, TransferFun) ->
	case string:lexemes(Val, " ") of
		[Val] -> TransferFun(Val);
		[_|_] = Splited -> [TransferFun(Elem) || Elem <- Splited]
	end.