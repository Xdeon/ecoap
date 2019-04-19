# !/bin/sh
gmake 
erl -pa ./ebin -pa ./deps/*/ebin +K true +spp true -sname benchmark -s benchmark start
