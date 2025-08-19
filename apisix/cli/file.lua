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

local ngx = ngx
local yaml = require("lyaml")
local profile = require("apisix.core.profile")
local util = require("apisix.cli.util")
local dkjson = require("dkjson")
local pairs = pairs
local type = type
local tonumber = tonumber
local getenv = os.getenv
local str_gmatch = string.gmatch
local str_find = string.find
local str_sub = string.sub
local print = print
local pl_path = require("pl.path")
local string = string
local table = table

local _M = {}
local exported_vars


function _M.get_exported_vars()
    return exported_vars
end


local function is_empty_yaml_line(line)
    return line == '' or str_find(line, '^%s*$') or str_find(line, '^%s*#')
end


local function tab_is_array(t)
    local count = 0
    for k, v in pairs(t) do
        count = count + 1
    end

    return #t == count
end


local function resolve_conf_var(conf)
    for key, val in pairs(conf) do
        if type(val) == "table" then
            local ok, err = resolve_conf_var(val)
            if not ok then
                return nil, err
            end

        elseif type(val) == "string" then
            local err
            local var_used = false
            -- we use '${{var}}' because '$var' and '${var}' are taken
            -- by Nginx
            local new_val = val:gsub("%$%{%{%s*([%w_]+[%:%=]?.-)%s*%}%}", function(var)
                local i, j = var:find("%:%=")
                local default
                if i and j then
                    default = var:sub(i + 2, #var)
                    default = default:gsub('^%s*(.-)%s*$', '%1')
                    var = var:sub(1, i - 1)
                end

                local v = getenv(var) or default
                if v then
                    if not exported_vars then
                        exported_vars = {}
                    end

                    exported_vars[var] = v
                    var_used = true
                    return v
                end

                err = "failed to handle configuration: " ..
                      "can't find environment variable " .. var
                return ""
            end)

            if err then
                return nil, err
            end

            if var_used then
                if tonumber(new_val) ~= nil then
                    new_val = tonumber(new_val)
                elseif new_val == "true" then
                    new_val = true
                elseif new_val == "false" then
                    new_val = false
                end
            end

            conf[key] = new_val
        end
    end

    return true
end


_M.resolve_conf_var = resolve_conf_var

local function replace_by_reserved_env_vars(conf, overwrite_temporary_file)
    if not conf["deployment"] or not conf["deployment"]["etcd"] then
        return
    end

    local path = "/tmp/"
    local v = getenv("API7_DP_MANAGER_ENDPOINTS") or getenv("API7_CONTROL_PLANE_ENDPOINTS")
                    or getenv("APISIX_DEPLOYMENT_ETCD_HOST")
    if v then
        local val, _, err = dkjson.decode(v)
        if err or not val then
            print("parse ${API7_DP_MANAGER_ENDPOINTS} failed, error:", err)
            return
        end

        conf["deployment"]["etcd"]["host"] = val
    end

    conf["deployment"]["etcd"]["tls"] = conf["deployment"]["etcd"]["tls"] or {}

    local sni = getenv("API7_DP_MANAGER_SNI") or getenv("API7_CONTROL_PLANE_SNI")
    if sni then
        conf["deployment"]["etcd"]["tls"]["sni"] = sni
    end

    local cp_cert = getenv("API7_DP_MANAGER_CERT") or getenv("API7_CONTROL_PLANE_CERT")
    local cp_key = getenv("API7_DP_MANAGER_KEY") or getenv("API7_CONTROL_PLANE_KEY")

    if not cp_cert or not cp_key then
        return
    end

    local cert_path = path .. "api7ee.crt"
    local key_path = path .. "api7ee.key"
    if overwrite_temporary_file then
        local ok, err = util.write_file(cert_path, cp_cert)
        if not ok then
            util.die("failed to update cert: ", err, "\n")
        end
        local ok, err = util.write_file(key_path, cp_key)
        if not ok then
            util.die("failed to update key: ", err, "\n")
        end
    end

    conf["deployment"]["etcd"]["tls"]["cert"] = cert_path
    conf["deployment"]["etcd"]["tls"]["key"] = key_path

    local ca = getenv("API7_DP_MANAGER_CA") or getenv("API7_CONTROL_PLANE_CA")
    if not ca then
        return
    end

    local ca_path = path .. "api7ee_ca.crt"
    if overwrite_temporary_file then
        local ok, err = util.write_file(ca_path, ca)
        if not ok then
            util.die("failed to update ca cert: ", err, "\n")
        end
    end

    conf["apisix"]["ssl"] = conf["apisix"]["ssl"] or {}
    if conf["apisix"]["ssl"]["ssl_trusted_certificate"] then
        conf["apisix"]["ssl"]["ssl_trusted_certificate"]
            = conf["apisix"]["ssl"]["ssl_trusted_certificate"] .. ", " .. ca_path
    else
        conf["apisix"]["ssl"]["ssl_trusted_certificate"] = ca_path
    end
end


local function path_is_multi_type(path, type_val)
    if str_sub(path, 1, 14) == "nginx_config->" and
            (type_val == "number" or type_val == "string") then
        return true
    end

    if path == "apisix->node_listen" and type_val == "number" then
        return true
    end

    if path == "apisix->ssl->key_encrypt_salt" then
        return true
    end

    return false
end


local function merge_conf(base, new_tab, ppath)
    ppath = ppath or ""

    for key, val in pairs(new_tab) do
        if type(val) == "table" then
            if val == yaml.null then
                base[key] = nil

            elseif tab_is_array(val) then
                base[key] = val

            else
                if base[key] == nil then
                    base[key] = {}
                end

                local ok, err = merge_conf(
                    base[key],
                    val,
                    ppath == "" and key or ppath .. "->" .. key
                )
                if not ok then
                    return nil, err
                end
            end
        else
            local type_val = type(val)

            if base[key] == nil then
                base[key] = val
            elseif type(base[key]) ~= type_val then
                local path = ppath == "" and key or ppath .. "->" .. key

                if path_is_multi_type(path, type_val) then
                    base[key] = val
                else
                    return nil, "failed to merge, path[" .. path ..  "] expect: " ..
                                type(base[key]) .. ", but got: " .. type_val
                end
            else
                base[key] = val
            end
        end
    end

    return base
end


function _M.read_yaml_conf(apisix_home, overwrite_temporary_file, plugins_warning)
    if apisix_home then
        profile.apisix_home = apisix_home .. "/"
    end

    local local_conf_path = profile:yaml_path("config-default")
    local default_conf_yaml, err = util.read_file(local_conf_path)
    if not default_conf_yaml then
        return nil, err
    end

    local default_conf = yaml.load(default_conf_yaml)
    if not default_conf then
        return nil, "invalid config-default.yaml file"
    end

    local_conf_path = profile:customized_yaml_path()
    if not local_conf_path then
        local_conf_path = profile:yaml_path("config")
    end
    local user_conf_yaml, err = util.read_file(local_conf_path)
    if not user_conf_yaml then
        return nil, err
    end

    local is_empty_file = true
    for line in str_gmatch(user_conf_yaml .. '\n', '(.-)\r?\n') do
        if not is_empty_yaml_line(line) then
            is_empty_file = false
            break
        end
    end

    if not is_empty_file then
        local user_conf = yaml.load(user_conf_yaml)
        if not user_conf then
            return nil, "invalid config.yaml file"
        end

        local ok, err = resolve_conf_var(user_conf)
        if not ok then
            return nil, err
        end

        if plugins_warning then
            if user_conf.plugins then
                print("WARNING: the plugins in config.yaml is no longer supported "
                        .. "and will be ignored.")
            end
            if user_conf.stream_plugins then
                print("WARNING: the stream_plugins in config.yaml is no longer supported "
                        .. "and will be ignored.")
            end
        end

        ok, err = merge_conf(default_conf, user_conf)
        if not ok then
            return nil, err
        end
    end

    if default_conf.deployment then
        default_conf.deployment.config_provider = "etcd"
        if default_conf.deployment.role == "traditional" then
            default_conf.etcd = default_conf.deployment.etcd

        elseif default_conf.deployment.role == "control_plane" then
            default_conf.etcd = default_conf.deployment.etcd
            default_conf.apisix.enable_admin = true

        elseif default_conf.deployment.role == "data_plane" then
            default_conf.etcd = default_conf.deployment.etcd
            if default_conf.deployment.role_data_plane.config_provider == "yaml" then
                default_conf.deployment.config_provider = "yaml"
            elseif default_conf.deployment.role_data_plane.config_provider == "json" then
                default_conf.deployment.config_provider = "json"
            elseif default_conf.deployment.role_data_plane.config_provider == "xds" then
                default_conf.deployment.config_provider = "xds"
            end
            default_conf.apisix.enable_admin = false
        end
    end

    --- using `not ngx` to check whether the current execution environment is apisix cli module,
    --- because it is only necessary to parse and validate `apisix.yaml` in apisix cli.
    if default_conf.deployment.config_provider == "yaml" and not ngx then
        local apisix_conf_path = profile:yaml_path("apisix")
        local apisix_conf_yaml, _ = util.read_file(apisix_conf_path)
        if apisix_conf_yaml then
            local apisix_conf = yaml.load(apisix_conf_yaml)
            if apisix_conf then
                local ok, err = resolve_conf_var(apisix_conf)
                if not ok then
                    return nil, err
                end
            end
        end
    end

    replace_by_reserved_env_vars(default_conf, overwrite_temporary_file)

    -- set ssl cert
    if default_conf.apisix.ssl.ssl_trusted_certificate ~= nil then
        local combined_cert_filepath = default_conf.apisix.ssl.ssl_trusted_combined_path or
                                       profile.apisix_home .. "conf/cert/"
                                       ..".ssl_trusted_combined.pem"
        if overwrite_temporary_file then
            local cert_paths = {}
            local ssl_certificates = default_conf.apisix.ssl.ssl_trusted_certificate
            for cert_path in string.gmatch(ssl_certificates, '([^,]+)') do
                cert_path = util.trim(cert_path)
                if cert_path == "system" then
                    local trusted_certs_path, err = util.get_system_trusted_certs_filepath()
                    if not trusted_certs_path then
                        util.die(err)
                    end
                    table.insert(cert_paths, trusted_certs_path)
                else
                    -- During validation, the path is relative to PWD
                    -- When Nginx starts, the path is relative to conf
                    -- Therefore we need to check the absolute version instead
                    cert_path = pl_path.abspath(cert_path)
                    if not pl_path.exists(cert_path) then
                        util.die("certificate path", cert_path, "doesn't exist\n")
                    end

                    table.insert(cert_paths, cert_path)
                end
            end

            util.gen_trusted_certs_combined_file(combined_cert_filepath, cert_paths)
        end
        default_conf.apisix.ssl.ssl_trusted_certificate = combined_cert_filepath
    end

    return default_conf
end


return _M
