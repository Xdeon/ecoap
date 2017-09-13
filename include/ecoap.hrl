-define(DEFAULT_COAP_PORT, 5683).
-define(DEFAULT_COAPS_PORT, 5684).

-define(MAX_BLOCK_SIZE, 1024).
-define(MAX_BODY_SIZE, 8192).

-define(DEFAULT_MAX_AGE, 60).

-record(coap_content, {
	etag = undefined :: undefined | binary(),
	max_age = ?DEFAULT_MAX_AGE :: non_neg_integer(),
	format = undefined :: undefined | binary() | non_neg_integer(),
	options = #{} :: coap_message:optionset(),
	payload = <<>> :: binary()
}).

-type coap_content() :: #coap_content{}.