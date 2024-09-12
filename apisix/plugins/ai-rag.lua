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
local http = require("resty.http")
local ngx_req = ngx.req
local core = require("apisix.core")
local decorate = require("apisix.plugins.ai-prompt-decorator").__decorate
local next = next

local azure_ai_search_schema = {
    type = "object",
    properties = {
        endpoint = {
            type = "string",
        },
        api_key = {
            type = "string",
        },
    }
}

local azure_openai_embeddings = {
    type = "object",
    properties = {
        endpoint = {
            type = "string",
        },
        api_key = {
            type = "string",
        },
    },
    required = { "endpoint", "api_key" }
}


local schema = {
    type = "object",
    properties = {
        type = "object",
        embeddings_provider = {
            type = "object",
            properties = {
                azure_openai = azure_openai_embeddings
            },
            -- change to enum while implementing support for other search services
            required = { "azure_openai" },
        },
        vector_search_provider = {
            type = "object",
            properties = {
                azure_ai_search = azure_ai_search_schema
            },
            -- change to enum while implementing support for other search services
            required = { "azure_ai_search" }
        },
    },
    required = { "embeddings_provider", "vector_search_provider" }
}

local request_schema = {
    type = "object",
    properties = {
        ai_rag = {
            type = "object",
            properties = {
                vector_search = {},
                embeddings = {},
            },
            required = { "vector_search", "embeddings" }
        }
    }
}

local _M = {
    version = 0.1,
    priority = 1060, -- TODO check with other ai plugins
    name = "ai-rag",
    schema = schema,
}


function _M.check_schema(conf)
    -- TODO: check endpoint validity
    return core.schema.check(schema, conf)
end


function _M.access(conf, ctx)
    -- local conf = conf.rag
    -- if conf then
    local httpc = http.new()
    local body_tab, err = core.request.get_json_request_body_table()
    if not body_tab then
        return 400, err
    end
    if not body_tab["ai_rag"] then
        core.log.error("request body must have \"ai-rag\" field")
        return 400
    end

    local embeddings_provider = next(conf.embeddings_provider)
    local embeddings_provider_conf = conf.embeddings_provider[next(conf.embeddings_provider)]
    local embeddings_driver = require("apisix.plugins.ai-rag.embeddings." .. embeddings_provider)

    local vector_search_provider = next(conf.vector_search_provider)
    local vector_search_provider_conf = conf.vector_search_provider[vector_search_provider]
    local vector_search_driver = require("apisix.plugins.ai-rag.vector-search." .. vector_search_provider)

    local vs_req_schema = vector_search_driver.request_schema
    local emb_req_schema = embeddings_driver.request_schema

    request_schema.properties.ai_rag.properties.vector_search = vs_req_schema
    request_schema.properties.ai_rag.properties.embeddings = emb_req_schema

    local ok, err = core.schema.check(request_schema, body_tab)
    if not ok then
        core.log.error("request body fails schema check: ", err)
        return 400
    end

    local embeddings, status, err = embeddings_driver.get_embeddings(embeddings_provider_conf,
    body_tab["ai_rag"].embeddings, httpc)
    if not embeddings then
        core.log.error("could not get embeddings: ", err)
        return status, err
    end

    local search_body = body_tab["ai_rag"].vector_search
    search_body.embeddings = embeddings
    local res, status, err = vector_search_driver.search(vector_search_provider_conf, search_body, httpc)
    if not res then
        core.log.error("could not get vector_search result: ", err)
        return status, err
    end

    body_tab["ai_rag"] = nil
    local prepend = {
        {
            role = "user",
            content = res
        }
    }
    local decorator_conf = {
        prepend = prepend
    }
    if not body_tab.messages then
        body_tab.messages = {}
    end
    decorate(decorator_conf, body_tab)
    local req_body_json = core.json.encode(body_tab)
    ngx_req.set_body_data(req_body_json)
end


return _M
