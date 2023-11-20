local core = require("apisix.core")
local validator = require("resty.validator")
local ngx_req = ngx.req

local schema = {
    type = "object",
    properties = {
        spec = {
            description = "schema against which the request/response will be validated",
            type = "string",
            minLength = 1
        },
        verbose_errors = { -- TODO: try to leverage this feature to avoid creating an interned lua string for perf
            type = "boolean",
            default = false
        },
        skip_request_body_validation = {
            type = "boolean",
            default = false
        },
        skip_request_header_validation = {
            type = "boolean",
            default = false
        },
        skip_query_param_validation  = {
            type = "boolean",
            default = false
        },
        skip_path_params_validation  = {
            type = "boolean",
            default = false
        },
        required = {"spec"}
    }
}

local plugin_name = "oas-validator"

local _M = {
    version = 0.1,
    priority = 510,
    name = plugin_name,
    schema = schema,
}


function _M.check_schema(conf)
    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return false, err
    end

    local _, err = core.json.decode(conf.spec)
    if err then
      return false, "invalid JSON string provided, err: " .. err
    end

    return true
end


function _M.access(conf, ctx)
    local req_body_json = ""
    if not conf.skip_request_body_validation then
        local req_body, err = core.request.get_body()
        if err ~= nil then
            core.log.error("failed reading request body, err: " .. err)
            return 500, {message = "error reading the request body. err: " .. err}
        end
        req_body_json = tostring(core.json.encode(req_body))
        -- remove line escapes. TODO: take this to library level
        req_body_json = (req_body_json:gsub("\\n", "")):sub(2, -2):gsub("\\", "")
    end

    local headers_json
    if not conf.skip_request_header_validation then
        -- using ngx.req.get_headers instead of core.request.get_headers
        -- because kin-openapi lib expects raw headers
        local headers, err = ngx_req.get_headers(0, true)
        if err ~= nil then
            core.log.error("failed reading request headers, err: " .. err)
            return 500, {message = "error reading the request headers, err: " .. err}
        end
        headers_json = tostring(core.json.encode(headers))
    end

    local ok, err = validator.validate_request(core.request.get_method(), ctx.var.request_uri, headers_json, req_body_json, conf.spec, conf.skip_path_params_validation, conf.skip_query_param_validation)

    if not ok then
        core.log.error("error occured while validating request, err: " .. err)
        if not conf.verbose_errors then
            err = ""
        end
        return 400, {message = "failed to validate request, err: " .. err}
    end
end

return _M
