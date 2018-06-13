-record(coap_message, {
    type = undefined :: coap_message:coap_type(),
    code = undefined :: undefined | coap_message:coap_code(),  
    id = undefined :: coap_message:msg_id(), 
    token = <<>> :: binary(),
    options = #{} :: coap_message:optionset(),
    payload = <<>> :: binary()
}).