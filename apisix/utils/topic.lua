local require = require
local pairs = pairs
local ipairs = ipairs
local type = type
local tab_remove = table.remove
local core = require("apisix.core")

local topic_sids = {}
local sid_topics = {}

local _M = {}


---
--  Delete an element from an array.
--
-- @function array_delete
-- @tparam table array The array.
-- @tparam string val The value to delete.
-- @treturn bool The result of the delete.
-- @usage
-- local arr = {"a", "b", "c"}
-- local res = array_delete(arr, "b") -- true
-- local res = array_delete(arr, "d") -- false
local function array_delete(array, val)
    if type(array) ~= "table" then
        return nil
    end

    for i, v in ipairs(array) do
        if v == val then
            local item = tab_remove(array, i)
            return item == val
        end
    end

    return false
end


function _M.sub_put(sid, topics)
    if type(topics) ~= "table" or not sid then
        return
    end

    if not sid_topics[sid] then
        sid_topics[sid] = {}
    end

     -- remove old relations for sid
    for _, topic in ipairs(sid_topics[sid]) do
        if not core.table.array_find(topics, topic) then
            array_delete(topic_sids[topic], sid)
        end
    end

    -- set new relations for sid
    for _, topic in ipairs(topics) do
        if not topic_sids[topic] then
            topic_sids[topic] = {}
        end

        if not core.table.array_find(topic_sids[topic], sid) then
            core.table.insert(topic_sids[topic], sid)
        end
    end

    sid_topics[sid] = topics
end


function _M.sub_add(sid, topics)
    if type(topics) ~= "table" or not sid then
        return
    end

    for _, topic in ipairs(topics) do
        if not topic_sids[topic] then
            topic_sids[topic] = {}
        end

        if not core.table.array_find(topic_sids[topic], sid) then
            core.table.insert(topic_sids[topic], sid)
        end
    end

    if not sid_topics[sid] then
        sid_topics[sid] = {}
    end

    for _, topic in ipairs(topics) do
        if not core.table.array_find(sid_topics[sid], topic) then
            core.table.insert(sid_topics[sid], topic)
        end
    end
end


function _M.sub_delete(sid, topics)
    if type(topics) ~= "table" or not sid then
        return
    end

    for _, topic in ipairs(topics) do
        if not topic_sids[topic] then
            goto CONTINUE
        end

        array_delete(topic_sids[topic], sid)

        if #topic_sids[topic] == 0 then
            topic_sids[topic] = nil
        end

        ::CONTINUE::
    end

    if not sid_topics[sid] then
        sid_topics[sid] = {}
    end

    for _, topic in ipairs(topics) do
        array_delete(sid_topics[sid], topic)
    end

    -- clear empty objects
    if #sid_topics[sid] == 0 then
        sid_topics[sid] = nil
    end
end


function _M.get_sids_by_topic(topic)
    if not topic then
        return nil
    end

    return topic_sids[topic]
end


function _M.get_topics_by_sid(sid)
    if not sid then
        return nil
    end

    return sid_topics[sid]
end


function _M.get_all_topics()
    local topics = {}

    for topic, sids in pairs(topic_sids) do
        if sids and #sids > 0 then
            core.table.insert(topics, topic)
        end
    end

    if #topics == 0 then
        return nil
    end

    return topics
end


function _M.get_topic_count()
    return core.table.nkeys(topic_sids)
end


function _M.get_removed_topics(topics)
    if type(topics) ~= "table" then
        return
    end

    local removed = {}

    for _, topic in ipairs(topics) do
        if not topic_sids[topic] or #topic_sids[topic] == 0 then
            core.table.insert(removed, topic)
        end
    end

    return removed
end


function _M.disconnect(sid, subcribed_topics)
    if type(subcribed_topics) ~= "table" or not sid then
        return
    end

    for _, topic in ipairs(subcribed_topics) do
        if not topic_sids[topic] then
            goto CONTINUE
        end

        array_delete(topic_sids[topic], sid)

        if #topic_sids[topic] == 0 then
            topic_sids[topic] = nil
        end

        ::CONTINUE::
    end

    sid_topics[sid] = nil
end


return _M
