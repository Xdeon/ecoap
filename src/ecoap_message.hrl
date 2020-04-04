-record(coap_message, {
    type = undefined :: ecoap_message:coap_type(),
    code = undefined :: undefined | ecoap_message:coap_code(),  
    id = undefined :: ecoap_message:msg_id(), 
    token = <<>> :: ecoap_message:token(),
    options = #{} :: ecoap_message:optionset(),
    payload = <<>> :: ecoap_message:payload()
}).