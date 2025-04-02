wrk.method = "POST"
wrk.headers['Content-Type'] = 'application/json'
wrk.headers['Authorization'] = 'Bearer token'
wrk.body = '{"messages": [{"role": "system", "content": "You are a mathematician"}, {"role": "user", "content": "What is 1+1?"}], "stream": true}'
wrk.path = "/ai"
request = function()
    return wrk.format(wrk.method, wrk.path, wrk.headers, wrk.body)
end
