# !/bin/sh
gmake 
erl -pa ./ebin -pa ./deps/*/ebin +K true +spp true -name benchmark@127.0.0.1 -setcookie ecoap -s benchmark start
