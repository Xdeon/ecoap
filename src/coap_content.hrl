-record(coap_content, {
    payload = <<>> :: binary(),
    options = #{} :: coap_message:optionset()
}).