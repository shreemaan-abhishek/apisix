local insert_tab = table.insert
local select = select

local _M = {}


function _M.push(queue, ...)
    local count = select("#", ...)
    for i = 1, count, 1 do
        local buf = select(i, ...)
        if buf then
            insert_tab(queue, buf)
        end
    end

    return true
end


return _M
