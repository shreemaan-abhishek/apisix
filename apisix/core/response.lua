local encode_json = require("cjson.safe").encode
local ngx = ngx
local arg = ngx.arg
local ngx_print = ngx.print
local ngx_header = ngx.header
local ngx_add_header
if ngx.config.subsystem == "http" then
    local ngx_resp = require "ngx.resp"
    ngx_add_header = ngx_resp.add_header
end

local error = error
local select = select
local type = type
local ngx_exit = ngx.exit
local concat_tab = table.concat
local str_sub = string.sub
local tonumber = tonumber
local clear_tab = require("table.clear")
local pairs = pairs
local table = require("apisix.core.table")
local _M = {version = 0.1}

function _M.exit_insert_callback(func, conf)
    local ngx_ctx = ngx.ctx
    local exit_callback_funcs = ngx_ctx.apisix_exit_callback_funcs or {}
    table.insert_tail(exit_callback_funcs, func, conf)
    ngx_ctx.apisix_exit_callback_funcs = exit_callback_funcs
end


local function set_header(append, ...)
    if ngx.headers_sent then
      error("headers have already been sent", 2)
    end

    local count = select('#', ...)
    if count == 1 then
        local headers = select(1, ...)
        if type(headers) ~= "table" then
            -- response.set_header(name, nil)
            ngx_header[headers] = nil
            return
        end

        for k, v in pairs(headers) do
            if append then
                ngx_add_header(k, v)
            else
                ngx_header[k] = v
            end
        end

        return
    end

    for i = 1, count, 2 do
        if append then
            ngx_add_header(select(i, ...), select(i + 1, ...))
        else
            ngx_header[select(i, ...)] = select(i + 1, ...)
        end
    end
end


local resp_exit
do
    local t = {}
    local idx = 1

function resp_exit(code, ...)
    clear_tab(t)
    idx = 0

    if code and type(code) ~= "number" then
        idx = idx + 1
        t[idx] = code
        code = nil
    end

    if code then
        ngx.status = code
    end

    for i = 1, select('#', ...) do
        local v = select(i, ...)
        if type(v) == "table" then
            local body, err = encode_json(v)
            if err then
                error("failed to encode data: " .. err, -2)
            else
                idx = idx + 1
                t[idx] = body .. "\n"
            end

        elseif v ~= nil then
            idx = idx + 1
            t[idx] = v
        end
    end
    local body = concat_tab(t, "", 1, idx)
    local exit_callback_funcs = ngx.ctx.apisix_exit_callback_funcs
    if exit_callback_funcs then
        local cur_code = code
        local cur_body = body
        local cur_headers = {}
        for i = 1, #exit_callback_funcs, 2 do
            local callback_func = exit_callback_funcs[i]
            local callback_conf = exit_callback_funcs[i+1]
            cur_code, cur_body, cur_headers = callback_func(
                cur_code, cur_body, cur_headers,
                callback_conf)
        end
        ngx.status = cur_code

        if cur_headers and table.nkeys(cur_headers) > 0 then
            set_header(false, cur_headers)
        end

        if cur_body then
            ngx_print(cur_body)
        end
        if cur_code then
            ngx_exit(cur_code)
        end
        return
    end

    if idx > 0 then
        ngx_print(body)
    end

    if code then
        return ngx_exit(code)
    end
end

end -- do
_M.exit = resp_exit


function _M.say(...)
    resp_exit(nil, ...)
end



function _M.set_header(...)
    set_header(false, ...)
end

---
-- Add a header to the client response.
--
-- @function core.response.add_header
-- @usage
-- core.response.add_header("Apisix-Plugins", "no plugin")
function _M.add_header(...)
    set_header(true, ...)
end


function _M.get_upstream_status(ctx)
    -- $upstream_status maybe including multiple status, only need the last one
    return tonumber(str_sub(ctx.var.upstream_status or "", -3))
end


function _M.clear_header_as_body_modified()
    ngx.header.content_length = nil
    -- in case of upstream content is compressed content
    ngx.header.content_encoding = nil

    -- clear cache identifier
    ngx.header.last_modified = nil
    ngx.header.etag = nil
end


-- Hold body chunks and return the final body once all chunks have been read.
-- Usage:
-- function _M.body_filter(conf, ctx)
--  local final_body = core.response.hold_body_chunk(ctx)
--  if not final_body then
--      return
--  end
--  final_body = transform(final_body)
--  ngx.arg[1] = final_body
--  ...
function _M.hold_body_chunk(ctx, hold_the_copy, max_resp_body_bytes)
    local body_buffer
    local chunk, eof = arg[1], arg[2]

    if not ctx._body_buffer then
        ctx._body_buffer = {}
    end

    if type(chunk) == "string" and chunk ~= "" then
        body_buffer = ctx._body_buffer[ctx._plugin_name]
        if not body_buffer then
            body_buffer = {
                chunk,
                n = 1
            }
            ctx._body_buffer[ctx._plugin_name] = body_buffer
            ctx._resp_body_bytes = #chunk
        else
            local n = body_buffer.n + 1
            body_buffer.n = n
            body_buffer[n] = chunk
            ctx._resp_body_bytes = ctx._resp_body_bytes + #chunk
        end
        if max_resp_body_bytes and ctx._resp_body_bytes >= max_resp_body_bytes then
            local body_data = concat_tab(body_buffer, "", 1, body_buffer.n)
            body_data = str_sub(body_data, 1, max_resp_body_bytes)
            return body_data
        end
    end

    if eof then
        body_buffer = ctx._body_buffer[ctx._plugin_name]
        if not body_buffer then
            if max_resp_body_bytes and #chunk >= max_resp_body_bytes then
                chunk = str_sub(chunk, 1, max_resp_body_bytes)
            end
            return chunk
        end

        local body_data = concat_tab(body_buffer, "", 1, body_buffer.n)
        ctx._body_buffer[ctx._plugin_name] = nil
        return body_data
    end

    if not hold_the_copy then
        -- flush the origin body chunk
        arg[1] = nil
    end
    return nil
end


return _M
