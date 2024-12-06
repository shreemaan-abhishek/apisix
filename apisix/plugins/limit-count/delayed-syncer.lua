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

local core = require("apisix.core")
local resty_lock = require "resty.lock"
local cjson_safe = require "cjson.safe"
local table_new = require("table.new")
local table_nkeys = require("table.nkeys")

local setmetatable = setmetatable
local tostring = tostring
local pairs = pairs
local ipairs = ipairs
local ngx_now = ngx.now
local worker_id = ngx.worker.id

local shdict_name = "plugin-limit-count"
local shd = ngx.shared[shdict_name]
assert(shd, "get shared dict(" .. shdict_name .. ") failed")

local KEY_PREFIX_LOCKER = "locker#"
local KEY_PREFIX_LOCAL_DELTA = "local_delta#" -- delta since last time sync with redis
local KEY_PREFIX_LOCAL_DELTA_KEYS = "local_delta_keys#" -- keys to be sync with redis next time
local KEY_PREFIX_SYNC_TIMER = "sync_timer#" -- per plugin instance timer, in server instance dimension
local KEY_PREFIX_REMOTE_QUOTA = "remote_quota#" -- save remaining/reset/sync_at in JSON format

local time_to_sync_records = {}

local _M = {}

local mt = {
    __index = _M
}


function _M.build_key(self, prefix, key)
    if self.shd_per_worker then
        return prefix .. worker_id() .. "#" .. key
    end
    return prefix .. key
end


function _M.key_locker(self, key)
    return self:build_key(KEY_PREFIX_LOCKER, key)
end


function _M.key_local_delta(self, key)
    return self:build_key(KEY_PREFIX_LOCAL_DELTA, key)
end


function _M.key_local_delta_keys(self, syncer_id)
    return self:build_key(KEY_PREFIX_LOCAL_DELTA_KEYS, syncer_id)
end


function _M.key_sync_timer(self, syncer_id)
    return self:build_key(KEY_PREFIX_SYNC_TIMER, syncer_id)
end


function _M.key_remote_quota(self, key)
    return self:build_key(KEY_PREFIX_REMOTE_QUOTA, key)
end


function _M.sync_to_shm(self, key, remaining, reset, local_delta)
    local quota = {
        remaining = remaining,
        reset = reset,
        sync_at = ngx_now(),
    }

    local _, err, quota_json

    quota_json, err = cjson_safe.encode(quota)
    if err then
        core.log.error("encode remote_quota to json failed: ", err)
        return err
    end

    _, err = shd:set(self:key_remote_quota(key), quota_json)
    if err then
        core.log.error("set remote quota to shm failed: ", err, ", key: ", key)
        return err
    end

    _, err = shd:incr(self:key_local_delta(key), -local_delta, 0)
    if err then
        core.log.error("incr local delta shm to failed: ", err, ", key: ", key)
        return err
    end
end


function _M.release(self, syncer_id)
    shd:delete(self:key_sync_timer(syncer_id))
end


function _M.delayed_sync(self, key, cost, syncer_id)
    local locker, err = resty_lock:new(shdict_name)
    if not locker then
        core.log.error("new resty locker failed: ", err, ", syncer_id: ", syncer_id)
        return nil, nil, err
    end

    local elapsed
    elapsed, err = locker:lock(self:key_locker(key))
    if err then
        core.log.error("lock key(" .. key .. ") failed: ", err, ", elapsed: ", elapsed)
        return nil, nil, err
    end

    local remaining, reset
    remaining, reset, err = self:_delayed_sync(key, cost, syncer_id)

    local ok, err_unlock = locker:unlock()
    if not ok then
        core.log.error("unlock key(" .. key .. ") failed: ", err_unlock)
    end

    return remaining, reset, err
end


function _M._delayed_sync(self, key, cost, syncer_id)
    local _, remaining, reset, local_delta, remote_quota_json, err
    local_delta, err  = shd:get(self:key_local_delta(key))
    if err then
        return nil, nil, err
    end

    remote_quota_json, err = shd:get(self:key_remote_quota(key))
    if err then
        return nil, nil, err
    end

    local remote_remaining, remote_reset, sync_at, quota
    if remote_quota_json then
        quota, err = cjson_safe.decode(tostring(remote_quota_json))
        if err then
            core.log.error("decode remote_quota_json failed: ", err)
            return nil, nil, err
        end

        remote_remaining, remote_reset, sync_at = quota.remaining, quota.reset, quota.sync_at
        reset = remote_reset - (ngx_now() - sync_at)
        if reset < 0 then
            reset = 0 -- flag that indicates needing to sync with redis
            time_to_sync_records[syncer_id] = nil
        end
    end

    if not remote_quota_json or 0 == reset then
        local_delta = 0
        remote_remaining = 0
        remote_reset = 0
        local remaining_or_err
        _, remaining_or_err, reset = self.limiter:incoming(key, local_delta)
        if type(remaining_or_err) ~= "string" then
            remote_remaining = remaining_or_err
            remote_reset = reset
        elseif remaining_or_err ~= "rejected" then
            core.log.error("sync to redis failed: ", remaining_or_err, ", key: ", key)
            return nil, nil, remaining_or_err
        end

        err = self:sync_to_shm(key, remote_remaining, remote_reset, local_delta)
        if err then
            return nil, nil, err
        end
    end

    _, err = shd:lpush(self:key_local_delta_keys(syncer_id), key)
    if err then
        core.log.error("put the keys to be synchronized to redis into the queue failed: ",
                       err, ", key: ", key)
        return nil, nil, err
    end

    local key_sync_timer = self:key_sync_timer(syncer_id)

    -- timer has not started or has already triggered, try starting a new one
    local now = ngx_now()
    if not time_to_sync_records[syncer_id] or time_to_sync_records[syncer_id] <= now then
        local time_to_sync = now + self.sync_interval
        -- nginx server instance dimension, each plug-in instance corresponds to a timer
        -- shd:add - ensure only one worker can start timer
        local success
        success, err = shd:add(key_sync_timer, time_to_sync)
        if success then
            -- start timer ASAP
            ngx.timer.at(
                0,
                function (premature)
                    if not premature then
                        self:sync(syncer_id, time_to_sync)
                    end
                    self:release(syncer_id)
                end
            )
            time_to_sync_records[syncer_id] = time_to_sync
        elseif err == "exists" then
            -- other workers
            time_to_sync_records[syncer_id], err = shd:get(key_sync_timer)
            if err then
                core.log.error("get sync timer created time failed: ", err)
            end
        else
            core.log.error("try starting new timer failed: ", err)
            return nil, nil, err
        end
    end

    remaining = remote_remaining - local_delta - cost
    if 0 <= remaining then
        _, err = shd:incr(self:key_local_delta(key), cost, 0)
        if err then
            core.log.error("incr local delta to shm failed: ", err, ", key: ", key)
            return nil, nil, err
        end
    end

    return remaining, reset
end


function _M.sync(self, syncer_id, time_to_sync)
    local key_local_delta_keys = self:key_local_delta_keys(syncer_id) -- name of keys queue
    local local_delta_keys_dedup = {} -- duplicate removal
    while not ngx.worker.exiting() and time_to_sync > ngx_now() do
        local key, err = shd:rpop(key_local_delta_keys)
        if err then
            core.log.error("shdict.rpop failed: ", err, ", syncer_id: ", syncer_id)
            return
        end
        if key then
            if not local_delta_keys_dedup[key] then
                local_delta_keys_dedup[key] = true
            end
        else
            ngx.sleep(0.001)
        end
    end

    if ngx.worker.exiting() then
        core.log.info("sync interrupted due to worker exit")
        return
    end

    -- drain all remaining keys from the queue
    local key = {}
    while key ~= nil do
        local err
        key, err = shd:rpop(key_local_delta_keys)
        if err then
            core.log.error("shdict.rpop failed: ", err, ", syncer_id: ", syncer_id)
            return
        end

        if key then
            if not local_delta_keys_dedup[key] then
                local_delta_keys_dedup[key] = true
            end
        end
    end

    local nkeys = table_nkeys(local_delta_keys_dedup)
    local local_delta_keys_uniq = table_new(nkeys, 0)

    core.log.info(nkeys, " keys to be sync, time_to_sync: ", time_to_sync)

    for key, _ in pairs(local_delta_keys_dedup) do
        table.insert(local_delta_keys_uniq, key)
    end

    local locker, err = resty_lock:new(shdict_name)
    if not locker then
        core.log.error("new resty locker failed: ", err, ", syncer_id: ", syncer_id)
        return
    end

    local _, remaining_or_err, reset, delta, elapsed
    for _, key in ipairs(local_delta_keys_uniq) do
        elapsed, err = locker:lock(self:key_locker(key))
        if err then
            core.log.error("lock key(" .. key .. ") failed: ", err, ", elapsed: ", elapsed)
            return
        end

        delta, err = shd:get(self:key_local_delta(key))
        if err then
            core.log.error("get local delta from shm failed: ", err)
        end

        _, remaining_or_err, reset = self.limiter:incoming(key, delta)
        -- compat
        if type(remaining_or_err) ~= "string" then
            self:sync_to_shm(key, remaining_or_err, reset, delta)
        elseif remaining_or_err ~= "rejected" then
            core.log.error("sync to redis failed: ", remaining_or_err, ", key: ", key)
        else
            self:sync_to_shm(key, 0, reset, delta)
        end

        local ok, err_unlock = locker:unlock()
        if not ok then
            core.log.error("unlock key(" .. key .. ") failed: ", err_unlock)
        end
    end
end


function _M.new(limit, window, conf, limiter)
    local self = {
        conf = conf,
        limit = limit,
        window = window,
        limiter = limiter,
        sync_interval = conf.sync_interval,
    }
    -- self.shd_per_worker = true: simulate multiple nginx server instance
    if conf._shd_per_worker then
        self.shd_per_worker = true
    end
    return setmetatable(self, mt)
end


return _M
