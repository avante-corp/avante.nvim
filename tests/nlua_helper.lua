local cwd = vim.fn.getcwd()
local deps = os.getenv("DEPS_PATH") .. "/share/lua/5.1"
package.path = deps .. "/?.lua;" .. deps .. "/?/init.lua;" .. package.path

vim.opt.runtimepath:prepend(cwd)

package.preload["plenary.curl"] = function()
  return {
    get = function() error("plenary.curl.get was not stubbed for this test") end,
    post = function() error("plenary.curl.post was not stubbed for this test") end,
  }
end

return function(busted)
  local schedule = vim.schedule
  local callback_errors = {}
  local pending_callbacks = 0
  -- Neovim otherwise logs scheduled assertion failures without failing Busted.
  vim.schedule = function(callback)
    pending_callbacks = pending_callbacks + 1
    schedule(function()
      local ok, err = xpcall(callback, function(error) return debug.traceback(tostring(error), 2) end)
      pending_callbacks = pending_callbacks - 1
      if not ok then table.insert(callback_errors, err) end
    end)
  end

  local function check_scheduled_callbacks()
    local drained = false
    schedule(function() drained = true end)
    assert(
      vim.wait(1000, function() return drained and pending_callbacks == 0 end, 1),
      "scheduled callbacks did not drain"
    )
    local errors = callback_errors
    callback_errors = {}
    if #errors > 0 then error(table.concat(errors, "\n"), 0) end
    return nil, true
  end

  busted.subscribe({ "test", "end" }, check_scheduled_callbacks, { priority = 1 })
  busted.subscribe({ "suite", "end" }, function()
    local ok, err = pcall(check_scheduled_callbacks)
    vim.schedule = schedule
    if not ok then error(err, 0) end
    return nil, true
  end, { priority = 1 })
  return true
end
