counter = 0

request = function()
    local api_key = string.format("auth-%04d", counter)
    counter = (counter + 1) % 10000
    
    local headers = {}
    headers["X-API-KEY"] = api_key
    
    return wrk.format("GET", "/hello", headers)
end
