local M = {}

local function copy_url(url)
  local copied = pcall(vim.fn.setreg, "+", url)
  if not copied then copied = pcall(vim.fn.setreg, "*", url) end
  return copied
end

local function notify_fallback(provider_name, copy_target, reason)
  copy_url(copy_target)
  vim.notify(
    string.format(
      "%s login URL copied to clipboard (%s). Open it in your browser:\n%s",
      provider_name,
      reason,
      copy_target
    ),
    vim.log.levels.WARN
  )
end

local function run_copy_callback(opts, provider_name, auth_url, open_url, copy_target)
  if not opts.on_copy then return end
  opts.on_copy({
    provider_name = provider_name,
    auth_url = auth_url,
    open_url = open_url,
    copy_url = copy_target,
    close = function() end,
  })
end

---@param opts { provider_name?: string, auth_url: string, open_url?: string, copy_url?: string, on_open?: fun(ctx: { provider_name: string, auth_url: string, open_url: string, copy_url: string, close: fun() }), on_copy?: fun(ctx: { provider_name: string, auth_url: string, open_url: string, copy_url: string, close: fun() }), on_close?: fun() }
---@return boolean
function M.show_auth_url(opts)
  opts = opts or {}
  local provider_name = opts.provider_name or "Provider"
  local auth_url = opts.auth_url
  local open_url = opts.open_url or auth_url
  local copy_target = opts.copy_url or auth_url

  if type(auth_url) ~= "string" or auth_url == "" then
    vim.notify("OAuth URL is missing", vim.log.levels.ERROR)
    return false
  end

  if #vim.api.nvim_list_uis() == 0 then
    notify_fallback(provider_name, copy_target, "headless session")
    run_copy_callback(opts, provider_name, auth_url, open_url, copy_target)
    return false
  end

  local ok_popup, Popup = pcall(require, "nui.popup")
  if not ok_popup then
    notify_fallback(provider_name, copy_target, "nui unavailable")
    run_copy_callback(opts, provider_name, auth_url, open_url, copy_target)
    return false
  end

  local width = math.min(math.max(math.floor(vim.o.columns * 0.8), 70), 120)
  local height = math.min(math.max(math.floor(vim.o.lines * 0.4), 10), 16)

  local ok_create, popup = pcall(
    function()
      return Popup({
        position = "50%",
        size = {
          width = width,
          height = height,
        },
        enter = true,
        focusable = true,
        border = {
          style = "rounded",
          text = {
            top = string.format(" %s OAuth ", provider_name),
            top_align = "center",
          },
        },
        buf_options = {
          modifiable = false,
          readonly = true,
          buftype = "nofile",
          filetype = "AvanteOAuth",
        },
        win_options = {
          wrap = true,
          linebreak = true,
          winfixbuf = true,
        },
      })
    end
  )
  if not ok_create then
    notify_fallback(provider_name, copy_target, "failed to create popup")
    run_copy_callback(opts, provider_name, auth_url, open_url, copy_target)
    return false
  end

  local function close_popup()
    if popup and popup.winid and vim.api.nvim_win_is_valid(popup.winid) then popup:unmount() end
    if opts.on_close then opts.on_close() end
  end

  local function open_action()
    if opts.on_open then
      opts.on_open({
        provider_name = provider_name,
        auth_url = auth_url,
        open_url = open_url,
        copy_url = copy_target,
        close = close_popup,
      })
      return
    end

    local ok, err = pcall(vim.ui.open, open_url)
    if ok then
      vim.notify(string.format("Opened %s login URL in browser", provider_name), vim.log.levels.INFO)
    else
      copy_url(copy_target)
      vim.notify(
        string.format("Could not open browser (%s). URL copied to clipboard.", tostring(err)),
        vim.log.levels.WARN
      )
    end
    close_popup()
  end

  local function copy_url_action()
    local copied = copy_url(copy_target)
    if copied then
      vim.notify(string.format("Copied %s login URL to clipboard", provider_name), vim.log.levels.INFO)
    else
      vim.notify(string.format("Failed to copy %s login URL", provider_name), vim.log.levels.ERROR)
    end

    if opts.on_copy then
      opts.on_copy({
        provider_name = provider_name,
        auth_url = auth_url,
        open_url = open_url,
        copy_url = copy_target,
        close = close_popup,
      })
      return
    end

    close_popup()
  end

  local lines = {
    "",
    string.format("  Authenticate %s", provider_name),
    "",
  }
  table.insert(lines, "    [Enter]/[o] Open in browser")
  table.insert(lines, "    [u] Copy URL")
  table.insert(lines, "    [q]/[Esc] Close")
  vim.list_extend(lines, {
    "",
    "  Auth URL:",
    "  " .. auth_url,
  })
  local preloaded = false
  if popup.bufnr and vim.api.nvim_buf_is_valid(popup.bufnr) then
    preloaded = pcall(vim.api.nvim_buf_set_lines, popup.bufnr, 0, -1, false, lines)
  end

  local ok_mount = pcall(function() popup:mount() end)
  if not ok_mount then
    notify_fallback(provider_name, copy_target, "failed to mount popup")
    run_copy_callback(opts, provider_name, auth_url, open_url, copy_target)
    return false
  end

  if not preloaded then
    local ok_set = pcall(vim.api.nvim_buf_set_lines, popup.bufnr, 0, -1, false, lines)
    if not ok_set then
      local modifiable = vim.bo[popup.bufnr].modifiable
      vim.bo[popup.bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, lines)
      vim.bo[popup.bufnr].modifiable = modifiable
    end
  end

  popup:map("n", "<CR>", open_action, { noremap = true, silent = true })
  popup:map("n", "o", open_action, { noremap = true, silent = true })
  popup:map("n", "O", open_action, { noremap = true, silent = true })
  popup:map("n", "u", copy_url_action, { noremap = true, silent = true })
  popup:map("n", "U", copy_url_action, { noremap = true, silent = true })
  popup:map("n", "q", close_popup, { noremap = true, silent = true })
  popup:map("n", "<Esc>", close_popup, { noremap = true, silent = true })

  return true
end

return M
