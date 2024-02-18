local ngx = ngx
local type = type
local ipairs = ipairs
local require = require
local lfs = require("lfs")
local timer_at = ngx.timer.at
local timer_every = ngx.timer.every
local exiting = ngx.worker.exiting
local ngx_time = ngx.time
local ngx_update_time = ngx.update_time
local process = require("ngx.process")
local io_open = io.open
local os_date = os.date
local os_remove = os.remove
local os_rename = os.rename
local str_sub = string.sub
local str_format = string.format
local str_byte = string.byte
local string_rfind = require("pl.stringx").rfind
local shell = require("resty.shell")
local core = require("apisix.core")
local ngx_sleep = require("apisix.core.utils").sleep

local events
local events_list

local INTERVAL = 60 * 60                  -- rotate interval (unit: second)
local MAX_KEPT = 24 * 7                   -- max number of log files will be kept
local MAX_SIZE = -1                       -- max size of file will be rotated
local COMPRESSION_FILE_SUFFIX = ".tar.gz" -- compression file suffix
local rotate_time
local default_logs
local flush_size = 3000
local enable_compression = false
local DEFAULT_LOG_FILENAME = "ht_msg_push.log"
local plugin_name = "ht-ws-msg-pub"

local SLASH_BYTE = str_byte("/")

local MAX_BUFFERS_SIZE = 200000
local buffers = core.table.new(2000, 0)
local file_op

local enable_access_log
local log_append_str


local _M = {}


local function file_exists(path)
    local file = io_open(path, "r")
    if file then
        file:close()
    end
    return file ~= nil
end


function _M.get_buffers_size()
    return buffers and #buffers or 0
end


local plugin_attr

local function get_plugin_attr()
    if plugin_attr then
        return plugin_attr
    end

    local local_conf = core.config.local_conf()
    plugin_attr = local_conf.plugin_attr[plugin_name]
    return plugin_attr
end

local function get_log_path_info()
    local attr = get_plugin_attr()
    local log_path
    if attr then
        log_path = attr.log_path
    end

    local prefix = ngx.config.prefix()

    if log_path then
        -- relative path
        if str_byte(log_path) ~= SLASH_BYTE then
            log_path = prefix .. log_path
        end
        local n = string_rfind(log_path, "/")
        if n ~= nil and n ~= #log_path then
            local dir = str_sub(log_path, 1, n)
            local name = str_sub(log_path, n + 1)
            return dir, name
        end
    end

    return prefix .. "logs/", DEFAULT_LOG_FILENAME
end

local function tab_sort_comp(a, b)
    return a > b
end

local function scan_log_folder()
    local t = {}

    local log_dir, log_name = get_log_path_info()

    local compression_log_type = log_name .. COMPRESSION_FILE_SUFFIX
    for file in lfs.dir(log_dir) do
        local n = string_rfind(file, "__")
        if n ~= nil then
            local log_type = file:sub(n + 2)
            if log_type == log_name or log_type == compression_log_type then
                core.table.insert(t, file)
            end
        end
    end

    core.table.sort(t, tab_sort_comp)
    return t, log_dir
end

local function rename_file(log, date_str)
    local new_file
    if not log.new_file then
        core.log.warn(log.type, " is off")
        return
    end

    new_file = str_format(log.new_file, date_str)
    if file_exists(new_file) then
        core.log.info("file exist: ", new_file)
        return new_file
    end

    local ok, err = os_rename(log.file, new_file)
    if not ok then
        core.log.error("move file from ", log.file, " to ", new_file, " res:", ok, " msg:", err)
        return
    end

    return new_file
end

local function compression_file(new_file)
    if not new_file or type(new_file) ~= "string" then
        core.log.info("compression file: ", new_file, " invalid")
        return
    end

    local n = string_rfind(new_file, "/")
    local new_filepath = str_sub(new_file, 1, n)
    local new_filename = str_sub(new_file, n + 1)
    local com_filename = new_filename .. COMPRESSION_FILE_SUFFIX
    local cmd = str_format("cd %s && tar -zcf %s %s", new_filepath, com_filename, new_filename)
    core.log.info("log file compress command: " .. cmd)

    local ok, stdout, stderr, reason, status = shell.run(cmd)
    if not ok then
        core.log.error(
            "compress log file from ",
            new_filename,
            " to ",
            com_filename,
            " fail, stdout: ",
            stdout,
            " stderr: ",
            stderr,
            " reason: ",
            reason,
            " status: ",
            status
        )
        return
    end

    ok, stderr = os_remove(new_file)
    if stderr then
        core.log.error("remove uncompressed log file: ",
            new_file, " fail, err: ", stderr, "  res:", ok)
    end
end

local function init_default_logs()
    local filepath, filename = get_log_path_info()
    local logs_info = core.table.new(0, 3)
    logs_info.file = filepath .. filename
    logs_info.file_name = filename
    logs_info.new_file = filepath .. "/%s__" .. filename
    return logs_info
end

local function file_size(file)
    local attr = lfs.attributes(file)
    if attr then
        return attr.size
    end
    return 0
end

local function rotate_file(now_time, max_kept)
    local now_date = os_date("%Y-%m-%d_%H-%M-%S", now_time)
    local new_file = rename_file(default_logs, now_date)
    if not new_file then
        return
    end

    local ok, err = events.post(events_list._source, events_list.reopen_file)
    if not ok then
        core.log.error("failed to post event: ", err)
    end

    if enable_compression then
        -- Waiting for nginx reopen files
        -- to avoid losing logs during compression
        ngx_sleep(0.5)
        compression_file(new_file)
    end

    -- clean the oldest file
    local log_list, log_dir = scan_log_folder()
    for i = max_kept + 1, #log_list do
        local path = log_dir .. log_list[i]
        local ok, err = os_remove(path)
        if err then
            core.log.error("remove old log file: ", path, " err: ", err, "  res: ", ok)
        end
    end
end


local function rotate()
    local interval = INTERVAL
    local max_kept = MAX_KEPT
    local max_size = MAX_SIZE
    local conf = plugin_attr.log_rotate
    if conf then
        interval = conf.interval or interval
        max_kept = conf.max_kept or max_kept
        max_size = conf.max_size or max_size
        enable_compression = conf.enable_compression or enable_compression
    end

    core.log.info("ht_msg_log rotate interval:", interval)
    core.log.info("ht_msg_log rotate max keep:", max_kept)
    core.log.info("ht_msg_log rotate max size:", max_size)

    if not default_logs then
        default_logs = init_default_logs()
    end

    ngx_update_time()
    local now_time = ngx_time()
    if not rotate_time then
        rotate_time = now_time + interval - (now_time % interval)
        core.log.info("first init rotate time is: ", rotate_time)
        return
    end

    if now_time >= rotate_time then
        rotate_file(now_time, max_kept)

        -- reset rotate time
        rotate_time = rotate_time + interval
    elseif max_size > 0 and file_size(default_logs.file) >= max_size then
        rotate_file(now_time, max_kept)
    end
end


local function reopen_file(file)
    if file then
        file:flush()
        file:close()
    end

    local dir, file_name = get_log_path_info()
    local path = dir .. file_name
    local err

    file, err = io_open(path, "a")
    if not file then
        return nil, "failed to open file: " .. path .. ", error: " .. err
    end

    core.log.info("success to open file: ", path)
    return file
end


local function write_file_data(log_line)
    local err
    if not file_op then
        file_op, err = reopen_file()
        if not err then
            core.log.error("failed to reopen file, err: ", err)
            return
        end
    end

    local ok, err = file_op:write(log_line)
    if not ok then
        core.log.error("failed to write file, error info: ", err)
        file_op = reopen_file(file_op)
    end
end


function _M.access_log(entry)
    if not enable_access_log then
        return
    end

    core.table.insert(buffers, entry)
end


local function flush_log(premature)
    if premature then
        return
    end

    core.log.info("flush log timer start, plugin name: ",
        plugin_name, ", worker_id: ", ngx.worker.id())

    if not file_op then
        local file, err = reopen_file()
        if not file then
            core.log.error("failed to open file, error: ", err)
            return
        end
        file_op = file
    end

    local log_flush_interval =  plugin_attr and plugin_attr.log_flush_interval or 0.05

    while not exiting() do
        while #buffers == 0 do
            if exiting() then
                return
            end
            ngx_sleep(0.05)
        end

        local cache_size = 0
        local re_new = #buffers > MAX_BUFFERS_SIZE and true or false
        for _, entry in ipairs(buffers) do
            core.table.insert(entry, "\n")
            local log_line = core.table.concat(entry, " ")
            write_file_data(log_line)

            cache_size = cache_size + #log_line

            if cache_size >= flush_size and file_op then
                file_op:flush()
                cache_size = 0
            end
        end

        if file_op then
            file_op:flush()
        end

        core.table.clear(buffers)
        if re_new then
            buffers = core.table.new(4000, 0)
        end

        ngx_sleep(log_flush_interval)
    end
end


function _M.push_log(message)
    _M.access_log(
        {
            ngx.utctime(),
            "[API7 Gateway] Push Message",
            message,
            log_append_str,
        }
    )
end


function _M.sub_log(message)
    _M.access_log(
        {
            ngx.utctime(),
            "[API7 Gateway] Subscribe Topics",
            message,
            log_append_str,
        }
    )
end


function _M.init()
    -- get plugin attr
    plugin_attr = get_plugin_attr()
    if not plugin_attr or not plugin_attr.enable_log then
        core.log.info("no plugin attr for: ", plugin_name)
        return
    end

    local is_worker = true
    if process.type() == "privileged agent" then
        is_worker = false
    end

    events = require("resty.worker.events")

    events_list = events.event_list(
        "plugins_" .. plugin_name .. "_log_event",
        "reopen_file"
    )

    if is_worker then
        log_append_str = plugin_attr.log_append_str == "" and nil or plugin_attr.log_append_str
        -- register close file event
        events.register(
            function(data, event, source, pid)
                core.log.info("log rotate event arrived")
                file_op = reopen_file(file_op)
            end,
            events_list._source,
            events_list.reopen_file
        )

        -- start flush log timer
        enable_access_log = true
        timer_at(0, flush_log)
    else
        -- start rotate timer
        if plugin_attr.enable_log_rotate then
            core.log.info("enable log rotate: ",
                core.json.delay_encode(plugin_attr.enable_log_rotate, true))
            timer_every(1, rotate)
        end
    end
end


return _M
