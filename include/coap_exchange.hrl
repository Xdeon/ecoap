-record(exchange, {
	timestamp = undefined :: non_neg_integer(),
	expire_time = undefined :: undefined | non_neg_integer(),
	stage = undefined :: atom(),
	sock = undefined :: inet:socket(),
	ep_id = undefined :: coap_endpoint_id(),
	endpoint_pid = undefined :: pid(),
	trid = undefined :: {in, non_neg_integer()} | {out, non_neg_integer()},
	handler_sup = undefined :: undefined | pid(),
	receiver = undefined :: undefined | {pid(), term()},
	msgbin = undefined :: undefined | binary(),
	timer = undefined :: undefined | reference(),
	retry_time = undefined :: undefined | non_neg_integer(),
	retry_count = undefined :: undefined | non_neg_integer()
	}).

-type coap_exchange() :: #exchange{}.