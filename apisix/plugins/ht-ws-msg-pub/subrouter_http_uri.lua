local require = require
local pairs = pairs
local ipairs  = ipairs
local type = type
local string = string
local str_lower = string.lower
local core   = require("apisix.core")
local router = require("apisix.router")
local base_router = require("apisix.http.route")

local _M = {}


local function get_subroutes(supper_route)
    local subroutes = {
        values = {},
        conf_version = 0,
    }

    if not router.router_http or not router.router_http.user_routes then
        return subroutes
    end

    local user_routes = router.router_http.user_routes
    subroutes.conf_version = user_routes.conf_version

    for _, route in ipairs(user_routes.values) do
        if type(route) == "table" and route.value.labels and
            route.value.labels.superior_id == supper_route.value.id then
            core.table.insert(subroutes.values, route)
        end
    end

    return subroutes
end


local uri_routes = {}
local uri_router
local match_opts = {}
local cached_router_version

local function matching(api_ctx)
    return base_router.match_uri(uri_router, match_opts, api_ctx)
end


local function match(api_ctx, user_routes)
    if not cached_router_version or cached_router_version ~= user_routes.conf_version then
        uri_router = base_router.create_radixtree_uri_router(user_routes.values,
                                                            uri_routes, false)
        cached_router_version = user_routes.conf_version
    end

    if not uri_router then
        core.log.error("failed to fetch valid `uri` router: ")
        return true
    end

    return matching(api_ctx)
end


function _M.header_to_var(header)
    local var = {}

    if not header then
        return var
    end

    for k, v in pairs(header) do
        k = str_lower(k)
        k = "http_" .. k:gsub("-", "_")
        var[k] = v
    end

    return var
end


function _M.match(uri, header, route)
    local subroutes = get_subroutes(route)

    local sub_ctx = {
        var = _M.header_to_var(header)
    }
    sub_ctx.var.uri = uri

    core.log.info("sub_ctx: ", core.json.delay_encode(sub_ctx))
    core.log.info("subroutes: ",
        core.json.delay_encode(subroutes, true))

    match(sub_ctx, subroutes)

    return sub_ctx.matched_route
end


return _M
