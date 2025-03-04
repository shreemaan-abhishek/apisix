local core = require("apisix.core")
local http = require("resty.http")
local env = core.env
local ngx_decode_base64 = ngx.decode_base64
local ngx_re = require("ngx.re")
local util = require("apisix.cli.util")

local schema = {
    type = "object",
    properties = {
        apiserver_addr = core.schema.uri_def,
        token = {
            type = "string",
            description = "Service account token for Kubernetes API authentication",
            minLength = 1,
        },
        token_file = {
            type = "string",
            minLength = 1,
        }
    },
    oneOf = {
        {required = {"apiserver_addr", "token"}},
        {required = {"apiserver_addr", "token_file"}}
    }
}

local _M = {
    schema = schema
}

local function get_token(conf)
    -- First try to use token from configuration
    if conf.token then
        local token, _ = env.fetch_by_uri(conf.token)
        if token then
            return token
        end
        return conf.token
    end

    -- Otherwise read from file
    local token, err = util.read_file(conf.token_file)
    if err then
        return nil, "failed to read token file: " .. (err or "unknown error")
    end
    if not token or token == "" then
        return nil, "empty token from file: " .. conf.token_file
    end

    return token
end

local function make_request_to_kubernetes(conf, namespace, secret_name)
    -- build request url
    local req_addr = conf.apiserver_addr .. "/api/v1/namespaces/" .. namespace ..
                    "/secrets/" .. secret_name

    local token, err = get_token(conf)
    if not token then
        return nil, "failed to get token: " .. (err or "unknown error")
    end

    local headers = {
        ["Authorization"] = "Bearer " .. token,
        ["Accept"] = "application/json",
    }

    local httpc = http.new()
    httpc:set_timeout(5000)

    local res, err = httpc:request_uri(req_addr, {
        method = "GET",
        headers = headers,
        ssl_verify = false
    })
    if not res then
        return nil, "failed to request Kubernetes API: " .. (err or "unknown error")
    end

    if res.status ~= 200 then
        return nil, "Kubernetes API returned non-200 status: " .. res.status ..
                   ", body: " .. (res.body or "")
    end

    return res.body
end

-- key format: namespace/secret_name/data_key
function _M.get(conf, key)
    core.log.info("fetching data from Kubernetes Secret for key: ", key)

    local parts, err = ngx_re.split(key, "/", "jo", nil, 3)
    if err then
        return nil, "failed to split key: " .. err
    end
    if not parts or #parts < 3 then
        return nil, "invalid key format, expected: namespace/secret_name/data_key, " ..
                  "got: " .. key
    end

    local namespace, secret_name, data_key = parts[1], parts[2], parts[3]
    if namespace == "" then
        return nil, "namespace cannot be empty, key: " .. key
    end
    if secret_name == "" then
        return nil, "secret_name cannot be empty, key: " .. key
    end
    if data_key == "" then
        return nil, "data_key cannot be empty, key: " .. key
    end
    core.log.info("namespace: ", namespace, ", secret_name: ", secret_name,
                 ", data_key: ", data_key)

    local res, err = make_request_to_kubernetes(conf, namespace, secret_name)
    if not res then
        return nil, "failed to retrieve data from Kubernetes Secret: " .. err
    end

    local secret_data, err = core.json.decode(res)
    if err then
        return nil, "failed to decode result: " .. err
    end
    if not secret_data or not secret_data.data then
        return nil, "no data field in Secret, res: " .. res
    end

    local value = secret_data.data[data_key]
    if not value then
        return nil, "key not found in Secret data: " .. data_key
    end

    -- Kubernetes Secret data field is base64 encoded
    local decoded_value = ngx_decode_base64(value)
    if not decoded_value then
        return nil, "failed to decode base64 value: " .. value
    end
    core.log.info("secret decoded_value: ", decoded_value)

    return decoded_value
end

return _M
