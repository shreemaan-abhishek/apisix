local str_sub = string.sub

local _M = {}


function _M.run_plugin(phase, plugins, api_ctx)
    if not plugins or #plugins == 0 then
        return
    end

    if phase ~= "log"
        and phase ~= "header_filter"
        and phase ~= "body_filter"
        and phase ~= "delayed_body_filter"
    then
        for i = 1, #plugins, 2 do
            if str_sub(plugins[i]["name"], 1, 7) ~= "ht-msg-" then
                goto CONTINUE
            end

            local phase_func
            if phase == "rewrite_in_consumer" then
                if plugins[i].type == "auth" then
                    plugins[i + 1]._skip_rewrite_in_consumer = true
                end
                phase_func = plugins[i]["rewrite"]
            else
                phase_func = plugins[i][phase]
            end

            if phase == "rewrite_in_consumer" and plugins[i + 1]._skip_rewrite_in_consumer then
                goto CONTINUE
            end

            if phase_func then
                local conf = plugins[i + 1]
                -- if not meta_filter(api_ctx, plugins[i]["name"], conf)then
                --     goto CONTINUE
                -- end

                api_ctx._plugin_name = plugins[i]["name"]
                local code, body = phase_func(conf, api_ctx)
                api_ctx._plugin_name = nil
                if code or body then
                    return code, body
                end
            end

            ::CONTINUE::
        end
        return
    end

    for i = 1, #plugins, 2 do
        if str_sub(plugins[i]["name"], 1, 7) ~= "ht-msg-" then
            goto CONTINUE2
        end

        local phase_func = plugins[i][phase]
        local conf = plugins[i + 1]
        if phase_func then  -- and meta_filter(api_ctx, plugins[i]["name"], conf)
            api_ctx._plugin_name = plugins[i]["name"]
            phase_func(conf, api_ctx)
            api_ctx._plugin_name = nil
        end

        ::CONTINUE2::
    end
end


return _M
