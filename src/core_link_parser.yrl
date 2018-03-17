%
% The contents of this file are subject to the Mozilla Public License
% Version 1.1 (the "License"); you may not use this file except in
% compliance with the License. You may obtain a copy of the License at
% http://www.mozilla.org/MPL/
%
% Copyright (c) 2015 Petr Gotthard <petr.gotthard@centrum.cz>
%

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

PARAM -> segment : {atomval('$1'), <<>>}.
PARAM -> segment '=' segment : {atomval('$1'), strval(atomval('$1'), '$3')}.
PARAM -> segment '=' string : {atomval('$1'), strval(atomval('$1'), '$3')}.

Erlang code.

atomval({_, _, Val}) -> list_to_atom(Val).

strval({_, _, Val}) -> list_to_binary(Val).

strval(title, {_, _, Val}) -> 
	list_to_binary(Val);
strval(sz, {_, _, Val}) -> 
	case catch {ok, list_to_integer(Val)} of
		{ok, Integer} -> Integer;
		{'EXIT', _} -> list_to_binary(Val)
	end;
strval(ct, {_, _, Val}) -> 
	maybe_multiple_strvals(Val, fun list_to_integer/1);
strval(_, {_, _, Val}) -> 
	maybe_multiple_strvals(Val, fun list_to_binary/1).

maybe_multiple_strvals(Val, TransferFun) ->
	case string:lexemes(Val, " ") of
		[Val] -> TransferFun(Val);
		[_|_] = Splited -> [TransferFun(Elem) || Elem <- Splited]
	end.