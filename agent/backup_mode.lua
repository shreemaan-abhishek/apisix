local log           = require("apisix.core.log")
local json          = require("apisix.core.json")
local etcd          = require("apisix.core.etcd")
local constants     = require("apisix.constants")
local config_local  = require("apisix.core.config_local")
local ngx_time      = ngx.time
local getenv        = os.getenv
local ngx_re        = require("ngx.re")
local ngx           = ngx

local BACKUP_RESOURCES_KIND = "resource configuration"
local BACKUP_DP_CONFIG_KIND = "dp configuration"

local _M = {}

local config_dict   = ngx.shared["config"]

local function put_to_s3(backup_conf, gw_id, item, kind)
    local s3 = require("resty.s3")
    local conf = backup_conf

    local bucket = conf.resource_bucket
    if kind == BACKUP_DP_CONFIG_KIND then
        bucket = conf.config_bucket
    end

    local ok, err = s3.put_object(
        bucket, gw_id, item, conf.region,
        conf.access_key, conf.secret_key, conf.endpoint)
    if not ok then
        log.error("failed to push ", kind, " backup to AWS S3: ", err)
    else
        log.info(kind, " backup pushed to AWS S3")
    end
end

local function put_to_azure_blob(backup_conf, gw_id, item, kind)
    local azure = require("resty.azblob")
    local conf = backup_conf

    local container = conf.resource_container
    if kind == BACKUP_DP_CONFIG_KIND then
        container = conf.config_container
    end

    local ok, err = azure.put_blob(
        conf.account_name, conf.account_key,
        container, gw_id, item, conf.endpoint)
    if not ok then
        log.error("failed to push ", kind, " backup to Azure Blob: ", err)
    else
        log.info(kind, " backup pushed to Azure Blob")
    end
end


function _M.backup_configuration(api7_agent)
    local current_time = ngx_time()
    if api7_agent.last_backup_time and current_time - api7_agent.last_backup_time < api7_agent.backup_interval then
        return
    end
    api7_agent.last_backup_time = current_time

    local local_conf = config_local.local_conf()
    if not local_conf or not local_conf.deployment or not local_conf.deployment.fallback_cp then
        return
    end

    local backup_conf = local_conf.deployment.fallback_cp
    if backup_conf.mode ~= "write" then
        return
    end

    local gw_id = getenv("API7_GATEWAY_GROUP_SHORT_ID")

    if not gw_id or gw_id == "" then
        log.error("gateway group id not found, skipping backup")
        return
    end

    local etcd_resp, err = etcd.get("/", true)
    if not etcd_resp then
        log.error("failed to fetch configuration from etcd for backup: ", err)
        return
    end

    -- Flatten the Etcd tree into resources
    local resources = {}
    local prefix = (local_conf.etcd and local_conf.etcd.prefix) or "/apisix"
    -- Ensure prefix ends with / for cleaner stripping
    if string.sub(prefix, -1) ~= "/" then
        prefix = prefix .. "/"
    end

    local function traverse(node)
        if not node then return end
        -- It's a key-value pair
        local key = node.key
        local value = node.value

        -- Filter out non-resource keys if necessary or just organize by type
        -- Key structure: /apisix/routes/1
        -- We want: resources["routes"] = [ { ... }, ... ]

        if string.find(key, prefix, 1, true) == 1 then
            local sub_key = string.sub(key, #prefix + 1)
            local parts, err = ngx_re.split(sub_key, "/")
            if not parts then
                log.error("failed to split key '", sub_key, "': ", err)
                return
            end
            if #parts > 0 then
                local res_type = parts[1]
                local res_key = "/" .. res_type
                if res_type and (constants.HTTP_ETCD_DIRECTORY[res_key] or constants.STREAM_ETCD_DIRECTORY[res_key]) then
                    if not resources[res_type] then
                        resources[res_type] = {}
                    end

                    local item = value
                    if type(value) == "string" then
                        local err
                        item, err = json.decode(value)
                        if not item then
                            log.error("failed to decode ", res_type, " value: ", err)
                            return
                        end
                    end

                    -- Clean metadata
                    if type(item) == "table" then
                        item.create_time = nil
                        item.update_time = nil
                        item.validity_start = nil
                        item.validity_end = nil
                        if res_type == "plugins" then
                            resources[res_type] = item
                        else
                            table.insert(resources[res_type], item)
                        end
                    end
                end
            end
        end
    end

    for _, value in ipairs(etcd_resp.body.list) do
        traverse(value)
    end
    local json_resources, err = json.encode(resources)
    if not json_resources then
        log.error("failed to encode resources: ", err)
        return
    end

    local dp_config = {
        config = {
            config_version = config_dict:get("config_version") or 0,
            config_payload = config_dict:get("config_payload") or {},
        }
    }
    local dp_config_payload, err = json.encode(dp_config)
    if not dp_config_payload then
        log.error("failed to encode dp config: ", err)
        return
    end

    -- Push to Storage
    if backup_conf.aws_s3 then
        put_to_s3(backup_conf.aws_s3, gw_id, json_resources, BACKUP_RESOURCES_KIND)
        put_to_s3(backup_conf.aws_s3, gw_id, dp_config_payload, BACKUP_DP_CONFIG_KIND)
    end

    if backup_conf.azure_blob then
        put_to_azure_blob(backup_conf.azure_blob, gw_id, json_resources, BACKUP_RESOURCES_KIND)
        put_to_azure_blob(backup_conf.azure_blob, gw_id, dp_config_payload, BACKUP_DP_CONFIG_KIND)
    end
end

return _M
