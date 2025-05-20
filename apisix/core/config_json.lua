--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--

--- Get configuration information in Stand-alone mode.
--
-- @module core.config_json

local config_local = require("apisix.core.config_local")
local config_util  = require("apisix.core.config_util")
local log          = require("apisix.core.log")
local json         = require("apisix.core.json")
local new_tab      = require("table.new")
local check_schema = require("apisix.core.schema").check
local profile      = require("apisix.core.profile")
local lfs          = require("lfs")
local file         = require("apisix.cli.file")
local exiting      = ngx.worker.exiting
local insert_tab   = table.insert
local type         = type
local ipairs       = ipairs
local setmetatable = setmetatable
local ngx_sleep    = require("apisix.core.utils").sleep
local ngx_timer_at = ngx.timer.at
local ngx_time     = ngx.time
local sub_str      = string.sub
local tostring     = tostring
local pcall        = pcall
local io           = io
local ngx          = ngx
local apisix_json_path = profile:json_path("apisix")
local created_obj  = {}


local _M = {
    version = 0.2,
    local_conf = config_local.local_conf,
    clear_local_cache = config_local.clear_cache,
}


local mt = {
    __index = _M,
    __tostring = function(self)
        return "apisix.json key: " .. (self.key or "")
    end
}


local apisix_json
local apisix_json_ctime
local function read_apisix_json(premature, pre_mtime)
    if premature then
        return
    end
    local attributes, err = lfs.attributes(apisix_json_path)
    if not attributes then
        log.error("failed to fetch ", apisix_json_path, " attributes: ", err)
        return
    end

    -- log.info("change: ", json.encode(attributes))
    local last_change_time = attributes.change
    if apisix_json_ctime == last_change_time then
        return
    end

    local f, err = io.open(apisix_json_path, "r")
    if not f then
        log.error("failed to open file ", apisix_json_path, " : ", err)
        return
    end
    local json_config = f:read("*a")
    f:close()

    local apisix_json_new = json.decode(json_config)
    if not apisix_json_new then
        log.error("failed to parse the content of file " .. apisix_json_path)
        return
    end

    local ok, err = file.resolve_conf_var(apisix_json_new)
    if not ok then
        log.error("failed: failed to resolve variables:" .. err)
        return
    end

    apisix_json = apisix_json_new
    apisix_json_ctime = last_change_time
end


local function sync_data(self)
    if not self.key then
        return nil, "missing 'key' arguments"
    end

    if not apisix_json_ctime then
        log.warn("wait for more time")
        return nil, "failed to read local file " .. apisix_json_path
    end

    if self.conf_version == apisix_json_ctime then
        return true
    end

    local items = apisix_json[self.key]
    log.info(self.key, " items: ", json.delay_encode(items))
    if not items then
        self.values = new_tab(8, 0)
        self.values_hash = new_tab(0, 8)
        self.conf_version = apisix_json_ctime
        return true
    end

    if self.values then
        for _, item in ipairs(self.values) do
            config_util.fire_all_clean_handlers(item)
        end
        self.values = nil
    end

    if self.single_item then
        -- treat items as a single item
        self.values = new_tab(1, 0)
        self.values_hash = new_tab(0, 1)

        local item = items
        local conf_item = {value = item, modifiedIndex = apisix_json_ctime,
                           key = "/" .. self.key}

        local data_valid = true
        local err
        if self.item_schema then
            data_valid, err = check_schema(self.item_schema, item)
            if not data_valid then
                log.error("failed to check item data of [", self.key,
                          "] err:", err, " ,val: ", json.delay_encode(item))
            end

            if data_valid and self.checker then
                data_valid, err = self.checker(item)
                if not data_valid then
                    log.error("failed to check item data of [", self.key,
                              "] err:", err, " ,val: ", json.delay_encode(item))
                end
            end
        end

        if data_valid then
            insert_tab(self.values, conf_item)
            self.values_hash[self.key] = #self.values
            conf_item.clean_handlers = {}

            if self.filter then
                self.filter(conf_item)
            end
        end

    else
        self.values = new_tab(#items, 0)
        self.values_hash = new_tab(0, #items)

        local err
        for i, item in ipairs(items) do
            local id = tostring(i)
            local data_valid = true
            if type(item) ~= "table" then
                data_valid = false
                log.error("invalid item data of [", self.key .. "/" .. id,
                          "], val: ", json.delay_encode(item),
                          ", it should be an object")
            end

            local key = item.id or "arr_" .. i
            local conf_item = {value = item, modifiedIndex = apisix_json_ctime,
                            key = "/" .. self.key .. "/" .. key}

            if data_valid and self.item_schema then
                data_valid, err = check_schema(self.item_schema, item)
                if not data_valid then
                    log.error("failed to check item data of [", self.key,
                              "] err:", err, " ,val: ", json.delay_encode(item))
                end
            end

            if data_valid and self.checker then
                data_valid, err = self.checker(item)
                if not data_valid then
                    log.error("failed to check item data of [", self.key,
                              "] err:", err, " ,val: ", json.delay_encode(item))
                end
            end

            if data_valid then
                insert_tab(self.values, conf_item)
                local item_id = conf_item.value.id or self.key .. "#" .. id
                item_id = tostring(item_id)
                self.values_hash[item_id] = #self.values
                conf_item.value.id = item_id
                conf_item.clean_handlers = {}

                if self.filter then
                    self.filter(conf_item)
                end
            end
        end
    end

    self.conf_version = apisix_json_ctime
    return true
end


function _M.get(self, key)
    if not self.values_hash then
        return
    end

    local arr_idx = self.values_hash[tostring(key)]
    if not arr_idx then
        return nil
    end

    return self.values[arr_idx]
end


local function _automatic_fetch(premature, self)
    if premature then
        return
    end

    local i = 0
    while not exiting() and self.running and i <= 32 do
        i = i + 1
        local ok, ok2, err = pcall(sync_data, self)
        if not ok then
            err = ok2
            log.error("failed to fetch data from local file " .. apisix_json_path .. ": ",
                      err, ", ", tostring(self))
            ngx_sleep(3)
            break

        elseif not ok2 and err then
            if err ~= "timeout" and err ~= "Key not found"
               and self.last_err ~= err then
                log.error("failed to fetch data from local file " .. apisix_json_path .. ": ",
                          err, ", ", tostring(self))
            end

            if err ~= self.last_err then
                self.last_err = err
                self.last_err_time = ngx_time()
            else
                if ngx_time() - self.last_err_time >= 30 then
                    self.last_err = nil
                end
            end
            ngx_sleep(0.5)

        elseif not ok2 then
            ngx_sleep(0.05)

        else
            ngx_sleep(0.1)
        end
    end

    if not exiting() and self.running then
        ngx_timer_at(0, _automatic_fetch, self)
    end
end


function _M.new(key, opts)
    local local_conf, err = config_local.local_conf()
    if not local_conf then
        return nil, err
    end

    local automatic = opts and opts.automatic
    local item_schema = opts and opts.item_schema
    local filter_fun = opts and opts.filter
    local single_item = opts and opts.single_item
    local checker = opts and opts.checker

    -- like /routes and /upstreams, remove first char `/`
    if key then
        key = sub_str(key, 2)
    end

    local obj = setmetatable({
        automatic = automatic,
        item_schema = item_schema,
        checker = checker,
        sync_times = 0,
        running = true,
        conf_version = 0,
        values = nil,
        routes_hash = nil,
        prev_index = nil,
        last_err = nil,
        last_err_time = nil,
        key = key,
        single_item = single_item,
        filter = filter_fun,
    }, mt)

    if automatic then
        if not key then
            return nil, "missing `key` argument"
        end

        local ok, ok2, err = pcall(sync_data, obj)
        if not ok then
            err = ok2
        end

        if err then
            log.error("failed to fetch data from local file ", apisix_json_path, ": ",
                      err, ", ", key)
        end

        ngx_timer_at(0, _automatic_fetch, obj)
    end

    if key then
        created_obj[key] = obj
    end

    return obj
end


function _M.close(self)
    self.running = false
end


function _M.server_version(self)
    return "apisix.json " .. _M.version
end


function _M.fetch_created_obj(key)
    return created_obj[sub_str(key, 2)]
end


function _M.init()
	read_apisix_json()
    return true
end


function _M.init_worker()
    -- sync data in each non-master process
    ngx.timer.every(1, read_apisix_json)

    return true
end


return _M
