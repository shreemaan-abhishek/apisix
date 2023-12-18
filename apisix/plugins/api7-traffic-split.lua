-- local common libs
local core       = require("apisix.core")
local upstream   = require("apisix.upstream")
local schema_def = require("apisix.schema_def")
local roundrobin = require("resty.roundrobin")
local ipmatcher  = require("resty.ipmatcher")
local expr       = require("resty.expr.v1")

-- local function
local core_log     = core.log
local ipairs       = ipairs
local pairs        = pairs
local table_insert = table.insert
local tostring     = tostring
local type         = type

local core_json_encode           = core.json.encode
local core_resolver_parse_domain = core.resolver.parse_domain
local core_schema_check          = core.schema.check
local core_string_format         = core.string.format
local core_table_clone           = core.table.clone
local core_table_merge           = core.table.merge
local core_utils_parse_addr      = core.utils.parse_addr

-- pre-defined resource
local lrucache = core.lrucache.new({
    count = 512,
    ttl = 0,
})

local exprs_schema = {
    type = "array",
}

local match_schema = {
    type = "array",
    items = {
        type = "object",
        properties = {
            exprs = exprs_schema,
        },
    },
}

local canary_upstreams_schema = {
    type = "array",
    items = {
        type = "object",
        properties = {
            upstream_name = schema_def.upstream_name,
            weight = {
                description = "used to split traffic between different"
                              .. "upstreams for plugin configuration",
                type = "integer",
                default = 1,
                minimum = 1,
                maximum = 100,
            },
        },
    },
    -- When the upstream configuration of the plugin is missing,
    -- the upstream of `route` is used by default.
    default = {
        {
            weight = 1,
        },
    },
    minItems = 1,
    maxItems = 20,
}

local schema = {
    type = "object",
    properties = {
        rules = {
            type = "array",
            items = {
                type = "object",
                properties = {
                    match = match_schema,
                    canary_upstreams = canary_upstreams_schema,
                },
            },
        },
        upstreams = {
            type = "array",
            items = {
                core_table_merge(core_table_clone(schema_def.upstream), {
                    -- add `name` require for plugin jsonschema validation
                    oneOf = {
                        {required = {"name", "id"}},
                    },
                }),
            },
            maxItems = 5,
        },
    },
    required = {"upstreams"},
}

local plugin_name = "api7-traffic-split"

local _M = {
    name = plugin_name,
    priority = 967,
    schema = schema,
    version = 0.1,
}

-- post-defined func
local function new_rr_obj(canary_upstreams, tbl_conf)
    local server_list = {}
    local weighted_upstreams = {}

    -- filtering canary weighted upstream
    for _, cupstream in ipairs(canary_upstreams) do
        if not cupstream.upstream_name then
            table_insert(weighted_upstreams, { weight = cupstream.weight })
            goto CONTINUE
        end

        for _, wupstream in ipairs(tbl_conf.upstreams) do
            if cupstream.upstream_name == wupstream.name then
                table_insert(weighted_upstreams, core_table_merge({
                    weight = cupstream.weight,
                }, wupstream))
            end
        end

        :: CONTINUE ::
    end

    --
    for i, upstream_obj in ipairs(weighted_upstreams) do
        if upstream_obj.id then
            server_list[upstream_obj.id] = upstream_obj.weight
        elseif upstream_obj.nodes then
            -- Add a virtual id field to uniquely identify the upstream key.
            upstream_obj.vid = i
            -- Get the table id of the nodes as part of the upstream_key,
            -- avoid upstream_key duplicate because vid is the same in the loop
            -- when multiple rules with multiple weighted_upstreams under each rule.
            -- see https://github.com/apache/apisix/issues/5276
            local node_tid = tostring(upstream_obj.nodes):sub(#"table: " + 1)
            upstream_obj.node_tid = node_tid
            server_list[upstream_obj] = upstream_obj.weight
        else
            -- If the upstream object has only the weight value, it means
            -- that the upstream weight value on the default route has been reached.
            -- Mark empty upstream services in the plugin.
            upstream_obj.upstream = "plugin#upstream#is#empty"
            server_list[upstream_obj.upstream] = upstream_obj.weight
        end
    end

    return roundrobin:new(server_list)
end

--
function _M.check_schema(conf)
    local ok, err = core_schema_check(schema, conf)

    if not ok then
        return false, err
    end

    if conf._meta and conf._meta.disable then
        return true
    end

    -- upstream name unique validation
    local upstream_hash = {}

    for idx, cupstream in ipairs(conf.upstreams) do
        if upstream_hash[cupstream.name] then
            return false, core_string_format("duplicate upstream [%d] name found: %s", idx, cupstream.name)
        end

        upstream_hash[cupstream.name] = true
    end

    -- traffic rules check
    if not conf.rules then
        return true
    end

    for idx, rule in ipairs(conf.rules) do
        if rule.canary_upstreams then
            for cidx, cupstream in ipairs(rule.canary_upstreams) do
                if cupstream.upstream_name and not upstream_hash[cupstream.upstream_name] then
                    return false, core_string_format("failed to fetch rules[%d].canary_upstreams[%d].upstream_name: "
                                                     .. "[%s] in conf.upstreams", idx, cidx, cupstream.upstream_name)
                end
            end
        end

        -- traffic match rule validation
        if not rule.match then
            goto CONTINUE
        end

        for _, m in ipairs(rule.match) do
            local ok, err = expr.new(m.exprs)
            if not ok then
                return false, "failed to validate the 'exprs' expression: " .. err
            end
        end

        :: CONTINUE ::
    end

    --
    return true
end


function _M.access(conf, ctx)
    if not conf or not conf.rules then
        return
    end

    local canary_upstreams
    local match_passed = true

    for _, rule in ipairs(conf.rules) do
        if not rule.match then
            match_passed = true
            canary_upstreams = rule.canary_upstreams
            break
        end

        for _, single_match in ipairs(rule.match) do
            local expr, err = expr.new(single_match.exprs)
            if err then
                core_log.error("exprs expression does not match: ", err)
                return 500, err
            end

            match_passed = expr:eval(ctx.var)
            if match_passed then
                break
            end
        end

        if match_passed then
            canary_upstreams = rule.canary_upstreams
            break
        end
    end

    core_log.info("match_passed: ", match_passed)

    if not match_passed then
        return
    end

    local rr_up, err = lrucache(canary_upstreams, ctx.conf_version, new_rr_obj, canary_upstreams, conf)
    if not rr_up then
        core_log.error("lrucache roundrobin failed: ", err)
        return 500
    end

    local upstream = rr_up:find()
    if upstream and upstream ~= "plugin#upstream#is#empty" then
        ctx.upstream_id = upstream
        core_log.info("upstream_id: ", upstream)
        return
    end

    ctx.upstream_id = nil
    core_log.info("route_up: ", upstream)
    return
end

--
return _M
