local ipairs    = ipairs
local pairs     = pairs
local re_split  = require("ngx.re").split
local core      = require("apisix.core")
local schema = {
    type = "object",
    properties = {
        allow_labels = {
            type = "object",
            minProperties = 1,
            patternProperties = {
                [".*"] = {
                    type = "array",
                    minItems = 1,
                    items = {type = "string"}
                },
            },
        },
        deny_labels = {
            type = "object",
            minProperties = 1,
            patternProperties = {
                [".*"] = {
                    type = "array",
                    minItems = 1,
                    items = {type = "string"}
                },
            },
        },
        rejected_code = {type = "integer", minimum = 200, default = 403},
        rejected_msg = {type = "string"}
    },
    anyOf = {
        {required = {"allow_labels"}},
        {required = {"deny_labels"}}
    },
}

local plugin_name = "acl"

local _M = {
    version = 0.1,
    priority = 2410,
    name = plugin_name,
    schema = schema,
}

local function contains_value(want_values, value_str)
    local values = { value_str }
    if core.string.find(value_str, ",") then
        local res, err = re_split(value_str, ",", "jo")
        if res then
            values = res
        else
            core.log.warn("failed to split labels [", value_str, "], err: ", err)
        end
    end
    for _, want in ipairs(want_values) do
        for _, value in ipairs(values) do
            if want == value then
                return true
            end
        end
    end
    return false
end

local function contains_label(want_labels, labels)
    if not labels then
        return false
    end
    for key, values in pairs(want_labels) do
        if labels[key] and contains_value(values, labels[key]) then
            return true
        end
    end
    return false
end

local function reject(conf)
    if conf.rejected_msg then
        return conf.rejected_code , { message = conf.rejected_msg }
    end
    return conf.rejected_code , { message = "The consumer is forbidden."}
end

function _M.check_schema(conf)
    local ok, err = core.schema.check(schema, conf)
   if not ok then
        return false, err
   end
   return true
end

function _M.access(conf, ctx)
    local consumer = ctx.consumer

    if not consumer then
        return 401, { message = "Missing authentication."}
    end

    if conf.deny_labels then
        if contains_label(conf.deny_labels, consumer.labels) then
            return reject(conf)
        end
    end

    if conf.allow_labels then
        if not contains_label(conf.allow_labels, consumer.labels) then
            return reject(conf)
        end
    end
end

return _M
