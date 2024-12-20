local sandbox = require("apisix.core.sandbox.base")
local _M = {}

local table = table
local pcall = pcall

-- try to load the lua function
-- @function core.sandbox.try_load
-- @tparam function func: The function to be safely executed
-- @treturn valid func if success to load Lua code
-- @treturn string error message if any. error message if fail to load Lua code(it maybe invalid)
-- @usage
-- local err, safe_loaded_func = core.sandbox.try_load("func(x,y) return x, y end")
function _M.try_load(func_lua)
    local ok, safe_loaded_func
    ok, safe_loaded_func = pcall(function ()
        return sandbox.protect(func_lua, {})
    end)
    if not ok then
        return nil, safe_loaded_func
    end
    return safe_loaded_func
end

-- try to run the `safe_loaded_func`
-- @function core.sandbox.try_run
-- @tparam function func: The safely loaded function to be executed
-- @tparam followed up with the arguments of the function
-- @treturn string error message if any.
-- This error will be produced when the function tries to use unsafe methods.
-- @treturn response of the function
-- @usage
-- local err, res1, res2 = core.sandbox.try_run(safe_loaded_func,1,2)
function _M.try_run(safe_loaded_func, ...)
    -- Note: The function passed should be a safe loaded function returned via try_load.
    -- If a normal function is passed, it will not be sandboxed.
    -- TODO: Add a check to ensure that the function passed is a safe loaded function.
    local ok, err, results
    ok, err = pcall(function(...)
        results = {safe_loaded_func(...)}
    end,...)

    if not ok then
        return err
    end
    -- luacheck: push ignore
    return nil, table.unpack(results)
    -- luacheck: pop
end

-- load the lua code and run it at same time in a simple way
-- Returns first argument as error followed by the return values of the function.
--
-- @function core.sandbox.simple_run
-- @tparam function func The function to be safely executed
-- @tparam rest of the arguments of the functions
-- @treturn string error message if any.
-- This error will be produced when the function tries to use unsafe methods.
-- @treturn response of the function
-- @usage
-- local err, res1, res2 = core.sandbox.simple_run("func(x,y) return x, y end",1,2)
function _M.simple_run(func_lua, ...)
    local safe_loaded_func, err = _M.try_load(func_lua)
    if err then
        return err
    end
    return _M.try_run(safe_loaded_func, ...)
end

return _M
