-record(ecoap_message, {
    type = undefined :: ecoap_message:coap_type(),
    code = undefined :: undefined | ecoap_message:coap_code(),  
    id = undefined :: ecoap_message:msg_id(), 
    token = <<>> :: binary(),
    options = #{} :: ecoap_message:optionset(),
    payload = <<>> :: binary()
}).