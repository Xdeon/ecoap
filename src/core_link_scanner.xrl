% PLACE FOR LICENSE

Definitions.

ALPHA = [a-zA-Z]
DIGIT = [0-9]
HEXDIG = ({DIGIT}|[a-fA-F])

PCT = %{HEXDIG}{HEXDIG}
PCHAR = ({ALPHA}|{DIGIT}|{PCT}|[-._~])

Rules.

<  : {token, {'<', TokenLine}}.
/  : {token, {'/', TokenLine}}.
>  : {token, {'>', TokenLine}}.
;  : {token, {';', TokenLine}}.
,  : {token, {',', TokenLine}}.
=  : {token, {'=', TokenLine}}.

{PCHAR}+  : {token, {segment, TokenLine, TokenChars}}.
"[^"]*"   : {token, {string, TokenLine, string:strip(TokenChars, both, $\")}}.

Erlang code.

%% Eliminate a dialyzer warning like below:
%% leexinc.hrl:268: Function yyrev/2 will never be called
-dialyzer({nowarn_function, yyrev/2}).