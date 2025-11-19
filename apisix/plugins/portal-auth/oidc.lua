local string = string
local pairs = pairs
local openidc = require("resty.openidc")
local consumer_mod = require("apisix.consumer")


local _M = {}


local function split_scopes_by_space(scope_string)
    local scopes = {}
    local count = 0
    if not scope_string then
        return scopes, count
    end
    for scope in string.gmatch(scope_string, "%S+") do
        scopes[scope] = true
        count = count + 1
    end
    return scopes, count
end


local function contains_any_scope(res, need_scopes)
    local token_scopes = split_scopes_by_space(res.scope)
    for scope, _ in pairs(need_scopes) do
        if token_scopes[scope] then
            return true
        end
    end
    return false
end


function _M.auth(conf, ctx)
    local opts = {
      discovery = conf.discovery,
    }
    local res, err = openidc.bearer_jwt_verify(opts)
    if err or not res then
        return 401, { message = err and err or "No access token provided" }
    end
    local matched_route = ctx.matched_route.value
    if matched_route.labels then
        local scopes_str = matched_route.labels["portal:dcr:require_any_scopes"]
        local scopes, count = split_scopes_by_space(scopes_str)
        if count > 0 and not contains_any_scope(res, scopes) then
            return 403, { message = "Insufficient scopes in access token" }
        end
    end

    if not res.azp then
        return 401, "missing azp claim in access token"
    end
    local developer, developer_conf, err2 =
                consumer_mod.find_consumer("oidc", "client_id", res.azp, ctx)
    if not developer then
        return 401, "failed to find developer: " .. (err2 or "invalid azp claim")
    end
    consumer_mod.attach_consumer(ctx, developer, developer_conf)

    -- same with openid-connect plugin
    ctx.external_user = res
end


return _M
