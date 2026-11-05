local Base = require("avante.llm_tools.base")
local Helpers = require("avante.llm_tools.helpers")
local Utils = require("avante.utils")
local Highlights = require("avante.highlights")
local Config = require("avante.config")

local PRIORITY = (vim.hl or vim.highlight).priorities.user
local NAMESPACE = vim.api.nvim_create_namespace("avante-diff")
local KEYBINDING_NAMESPACE = vim.api.nvim_create_namespace("avante-diff-keybinding")

---@class AvanteLLMTool
local M = setmetatable({}, Base)

M.name = "replace_in_file"

M.description =
  "Request to replace sections of content in an existing file using SEARCH/REPLACE blocks that define exact changes to specific parts of the file. This tool should be used when you need to make targeted changes to specific parts of a file."

M.support_streaming = true

function M.enabled() return false end

---@type AvanteLLMToolParam
M.param = {
  type = "table",
  fields = {
    {
      name = "path",
      description = "The path to the file in the current project scope",
      type = "string",
    },
    {
      --- IMPORTANT: Using "the_diff" instead of "diff" is to avoid LLM streaming generating function parameters in alphabetical order, which would result in generating "path" after "diff", making it impossible to achieve a streaming diff view.
      name = "the_diff",
      description = [[
One or more SEARCH/REPLACE blocks following this exact format:
  ```
  ------- SEARCH
  [exact content to find]
  =======
  [new content to replace with]
  +++++++ REPLACE
  ```

Example:
  ```
  ------- SEARCH
  func my_function(param1, param2) {
    // This is a comment
    console.log(param1);
  }
  =======
  func my_function(param1, param2) {
    // This is a modified comment
    console.log(param2);
  }
  +++++++ REPLACE
  ```

  Critical rules:
  1. SEARCH content must match the associated file section to find EXACTLY:
     * Do not refer to the `diff` argument of the previous `replace_in_file` function call for SEARCH content matching, as it may have been modified. Always match from the latest file content in <selected_files> or from the `view` function call result.
     * Match character-for-character including whitespace, indentation, line endings
     * Include all comments, docstrings, etc.
  2. SEARCH/REPLACE blocks will ONLY replace the first match occurrence.
     * Including multiple unique SEARCH/REPLACE blocks if you need to make multiple changes.
     * Include *just* enough lines in each SEARCH section to uniquely match each set of lines that need to change.
     * When using multiple SEARCH/REPLACE blocks, list them in the order they appear in the file.
  3. Keep SEARCH/REPLACE blocks concise:
     * Break large SEARCH/REPLACE blocks into a series of smaller blocks that each change a small portion of the file.
     * Include just the changing lines, and a few surrounding lines if needed for uniqueness.
     * Do not include long runs of unchanging lines in SEARCH/REPLACE blocks.
     * Each line must be complete. Never truncate lines mid-way through as this can cause matching failures.
  4. Special operations:
     * To move code: Use two SEARCH/REPLACE blocks (one to delete from original + one to insert at new location)
     * To delete code: Use empty REPLACE section
      ]],
      type = "string",
    },
  },
}

---@type AvanteLLMToolReturn[]
M.returns = {
  {
    name = "success",
    description = "True if the replacement was successful, false otherwise",
    type = "boolean",
  },
  {
    name = "error",
    description = "Error message if the replacement failed",
    type = "string",
    optional = true,
  },
}

--- IMPORTANT: Using "the_diff" instead of "diff" is to avoid LLM streaming generating function parameters in alphabetical order, which would result in generating "path" after "diff", making it impossible to achieve a streaming diff view.
---@type AvanteLLMToolFunc<{ path: string, the_diff?: string }>
function M.func(input, opts)
  local on_log = opts.on_log
  local on_complete = opts.on_complete
  local session_ctx = opts.session_ctx
  if not on_complete then return false, "on_complete not provided" end

  if not input.path or not input.the_diff then
    return false, "path and the_diff are required " .. vim.inspect(input)
  end
  if on_log then on_log("path: " .. input.path) end
  local abs_path = Helpers.get_abs_path(input.path)
  if not Helpers.has_permission_to_access(abs_path) then return false, "No permission to access path: " .. abs_path end

  local is_streaming = opts.streaming or false

  session_ctx.prev_streaming_diff_timestamp_map = session_ctx.prev_streaming_diff_timestamp_map or {}
  local current_timestamp = os.time()
  if is_streaming then
    local prev_streaming_diff_timestamp = session_ctx.prev_streaming_diff_timestamp_map[opts.tool_use_id]
    if prev_streaming_diff_timestamp ~= nil then
      if current_timestamp - prev_streaming_diff_timestamp < 2 then
        return false, "Diff hasn't changed in the last 2 seconds"
      end
    end
    local streaming_diff_lines_count = Utils.count_lines(input.the_diff)
    session_ctx.streaming_diff_lines_count_history = session_ctx.streaming_diff_lines_count_history or {}
    local prev_streaming_diff_lines_count = session_ctx.streaming_diff_lines_count_history[opts.tool_use_id]
    if streaming_diff_lines_count == prev_streaming_diff_lines_count then
      return false, "Diff lines count hasn't changed"
    end
    session_ctx.streaming_diff_lines_count_history[opts.tool_use_id] = streaming_diff_lines_count
  end

  local diff = Utils.fix_diff(input.the_diff)

  if on_log and diff ~= input.the_diff then on_log("diff fixed") end

  local diff_lines = vim.split(diff, "\n")

  local is_searching = false
  local is_replacing = false
  local current_old_lines = {}
  local current_new_lines = {}
  local rough_diff_blocks = {}

  for _, line in ipairs(diff_lines) do
    if line:match("^%s*-------* SEARCH") then
      is_searching = true
      is_replacing = false
      current_old_lines = {}
    elseif line:match("^%s*=======*") and is_searching then
      is_searching = false
      is_replacing = true
      current_new_lines = {}
    elseif line:match("^%s*+++++++* REPLACE") and is_replacing then
      is_replacing = false
      table.insert(rough_diff_blocks, { old_lines = current_old_lines, new_lines = current_new_lines })
    elseif is_searching then
      table.insert(current_old_lines, line)
    elseif is_replacing then
      -- Remove trailing spaces from each line before adding to new_lines
      table.insert(current_new_lines, (line:gsub("%s+$", "")))
    end
  end

  -- Handle streaming mode: if we're still in replace mode at the end, include the partial block
  if is_streaming and is_replacing and #current_old_lines > 0 then
    if #current_old_lines > #current_new_lines then
      current_old_lines = vim.list_slice(current_old_lines, 1, #current_new_lines)
    end
    table.insert(
      rough_diff_blocks,
      { old_lines = current_old_lines, new_lines = current_new_lines, is_replacing = true }
    )
  end

  if #rough_diff_blocks == 0 then
    -- Utils.debug("opts.diff", opts.diff)
    -- Utils.debug("diff", diff)
    local err = [[No diff blocks found.

Please make sure the diff is formatted correctly, and that the SEARCH/REPLACE blocks are in the correct order.]]
    return false, err
  end

  session_ctx.prev_streaming_diff_timestamp_map[opts.tool_use_id] = current_timestamp

  local bufnr, err = Helpers.get_bufnr(abs_path)
  if err then return false, err end

  session_ctx.undo_joined = session_ctx.undo_joined or {}
  local undo_joined = session_ctx.undo_joined[opts.tool_use_id]
  if not undo_joined then
    pcall(vim.cmd.undojoin)
    session_ctx.undo_joined[opts.tool_use_id] = true
  end

  local original_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local sidebar = require("avante").get()
  if not sidebar then return false, "Avante sidebar not found" end

  --- add line numbers to rough_diff_block
  local function complete_rough_diff_block(rough_diff_block)
    local old_lines = rough_diff_block.old_lines
    local new_lines = rough_diff_block.new_lines
    local start_line, end_line = Utils.fuzzy_match(original_lines, old_lines)
    if start_line == nil or end_line == nil then
      local old_string = table.concat(old_lines, "\n")
      return "Failed to find the old string:\n" .. old_string
    end
    local original_indentation = Utils.get_indentation(original_lines[start_line])
    if original_indentation ~= Utils.get_indentation(old_lines[1]) then
      old_lines = vim.tbl_map(function(line) return original_indentation .. line end, old_lines)
      new_lines = vim.tbl_map(function(line) return original_indentation .. line end, new_lines)
    end
    rough_diff_block.old_lines = old_lines
    rough_diff_block.new_lines = new_lines
    rough_diff_block.start_line = start_line
    rough_diff_block.end_line = end_line
    return nil
  end

  session_ctx.rough_diff_blocks_to_diff_blocks_cache_map = session_ctx.rough_diff_blocks_to_diff_blocks_cache_map or {}
  local rough_diff_blocks_to_diff_blocks_cache =
    session_ctx.rough_diff_blocks_to_diff_blocks_cache_map[opts.tool_use_id]
  if not rough_diff_blocks_to_diff_blocks_cache then
    rough_diff_blocks_to_diff_blocks_cache = {}
    session_ctx.rough_diff_blocks_to_diff_blocks_cache_map[opts.tool_use_id] = rough_diff_blocks_to_diff_blocks_cache
  end

  local function rough_diff_blocks_to_diff_blocks(rough_diff_blocks_)
    local res = {}
    local base_line_ = 0
    for idx, rough_diff_block in ipairs(rough_diff_blocks_) do
      local cache_key = string.format("%s:%s", idx, #rough_diff_block.new_lines)
      local cached_diff_blocks = rough_diff_blocks_to_diff_blocks_cache[cache_key]
      if cached_diff_blocks then
        res = vim.list_extend(res, cached_diff_blocks.diff_blocks)
        base_line_ = cached_diff_blocks.base_line
        goto continue
      end
      local old_lines = rough_diff_block.old_lines
      local new_lines = rough_diff_block.new_lines
      if rough_diff_block.is_replacing then
        new_lines = vim.list_slice(new_lines, 1, #new_lines - 1)
        old_lines = vim.list_slice(old_lines, 1, #new_lines)
      end
      local old_string = table.concat(old_lines, "\n")
      local new_string = table.concat(new_lines, "\n")
      local patch
      if Config.behaviour.minimize_diff then
        ---@diagnostic disable-next-line: assign-type-mismatch, missing-fields
        patch = vim.text.diff(old_string, new_string, { ---@type integer[][]
          algorithm = "histogram",
          result_type = "indices",
          ctxlen = vim.o.scrolloff,
        })
      else
        patch = { { 1, #old_lines, 1, #new_lines } }
      end
      local diff_blocks_ = {}
      for _, hunk in ipairs(patch) do
        local start_a, count_a, start_b, count_b = unpack(hunk)
        local diff_block = {}
        if count_a > 0 then
          diff_block.old_lines = vim.list_slice(rough_diff_block.old_lines, start_a, start_a + count_a - 1)
        else
          diff_block.old_lines = {}
        end
        if count_b > 0 then
          diff_block.new_lines = vim.list_slice(rough_diff_block.new_lines, start_b, start_b + count_b - 1)
        else
          diff_block.new_lines = {}
        end
        if count_a > 0 then
          diff_block.start_line = base_line_ + rough_diff_block.start_line + start_a - 1
        else
          diff_block.start_line = base_line_ + rough_diff_block.start_line + start_a
        end
        diff_block.end_line = base_line_ + rough_diff_block.start_line + start_a + math.max(count_a, 1) - 2
        table.insert(diff_blocks_, diff_block)
      end

      local distance = 0
      for _, hunk in ipairs(patch) do
        local _, count_a, _, count_b = unpack(hunk)
        distance = distance + count_b - count_a
      end

      local old_distance = #rough_diff_block.new_lines - #rough_diff_block.old_lines

      base_line_ = base_line_ + distance - old_distance

      if not rough_diff_block.is_replacing then
        rough_diff_blocks_to_diff_blocks_cache[cache_key] = { diff_blocks = diff_blocks_, base_line = base_line_ }
      end

      res = vim.list_extend(res, diff_blocks_)

      ::continue::
    end
    return res
  end

  for _, rough_diff_block in ipairs(rough_diff_blocks) do
    local error = complete_rough_diff_block(rough_diff_block)
    if error then
      on_complete(false, error)
      return
    end
  end

  local diff_blocks = rough_diff_blocks_to_diff_blocks(rough_diff_blocks)

  table.sort(diff_blocks, function(a, b) return a.start_line < b.start_line end)

  local base_line = 0
  for _, diff_block in ipairs(diff_blocks) do
    diff_block.new_start_line = diff_block.start_line + base_line
    diff_block.new_end_line = diff_block.new_start_line + #diff_block.new_lines - 1
    base_line = base_line + #diff_block.new_lines - #diff_block.old_lines
  end

  local function remove_diff_block(removed_idx, use_new_lines)
    local new_diff_blocks = {}
    local distance = 0
    for idx, diff_block in ipairs(diff_blocks) do
      if idx == removed_idx then
        if not use_new_lines then distance = #diff_block.old_lines - #diff_block.new_lines end
        goto continue
      end
      if idx > removed_idx then
        diff_block.new_start_line = diff_block.new_start_line + distance
        diff_block.new_end_line = diff_block.new_end_line + distance
      end
      table.insert(new_diff_blocks, diff_block)
      ::continue::
    end

    diff_blocks = new_diff_blocks
  end

  local function get_current_diff_block()
    local winid = Utils.get_winid(bufnr)
    local cursor_line = Utils.get_cursor_pos(winid)
    for idx, diff_block in ipairs(diff_blocks) do
      if cursor_line >= diff_block.new_start_line and cursor_line <= diff_block.new_end_line then
        return diff_block, idx
      end
    end
    return nil, nil
  end

  local function get_prev_diff_block()
    local winid = Utils.get_winid(bufnr)
    local cursor_line = Utils.get_cursor_pos(winid)
    local distance = nil
    local idx = nil
    for i, diff_block in ipairs(diff_blocks) do
      if cursor_line >= diff_block.new_start_line and cursor_line <= diff_block.new_end_line then
        local new_i = i - 1
        if new_i < 1 then return diff_blocks[#diff_blocks] end
        return diff_blocks[new_i]
      end
      if diff_block.new_start_line < cursor_line then
        local distance_ = cursor_line - diff_block.new_start_line
        if distance == nil or distance_ < distance then
          distance = distance_
          idx = i
        end
      end
    end
    if idx ~= nil then return diff_blocks[idx] end
    if #diff_blocks > 0 then return diff_blocks[#diff_blocks] end
    return nil
  end

  local function get_next_diff_block()
    local winid = Utils.get_winid(bufnr)
    local cursor_line = Utils.get_cursor_pos(winid)
    local distance = nil
    local idx = nil
    for i, diff_block in ipairs(diff_blocks) do
      if cursor_line >= diff_block.new_start_line and cursor_line <= diff_block.new_end_line then
        local new_i = i + 1
        if new_i > #diff_blocks then return diff_blocks[1] end
        return diff_blocks[new_i]
      end
      if diff_block.new_start_line > cursor_line then
        local distance_ = diff_block.new_start_line - cursor_line
        if distance == nil or distance_ < distance then
          distance = distance_
          idx = i
        end
      end
    end
    if idx ~= nil then return diff_blocks[idx] end
    if #diff_blocks > 0 then return diff_blocks[1] end
    return nil
  end

  local show_keybinding_hint_extmark_id = nil
  local augroup = vim.api.nvim_create_augroup("avante_replace_in_file", { clear = true })
  local function register_cursor_move_events()
    local function show_keybinding_hint(lnum)
      if show_keybinding_hint_extmark_id then
        vim.api.nvim_buf_del_extmark(bufnr, KEYBINDING_NAMESPACE, show_keybinding_hint_extmark_id)
      end

      local hint = string.format(
        "[<%s>: OURS, <%s>: THEIRS, <%s>: PREV, <%s>: NEXT]",
        Config.mappings.diff.ours,
        Config.mappings.diff.theirs,
        Config.mappings.diff.prev,
        Config.mappings.diff.next
      )

      show_keybinding_hint_extmark_id = vim.api.nvim_buf_set_extmark(bufnr, KEYBINDING_NAMESPACE, lnum - 1, -1, {
        hl_group = "AvanteInlineHint",
        virt_text = { { hint, "AvanteInlineHint" } },
        virt_text_pos = "right_align",
        priority = PRIORITY,
      })
    end

    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "WinLeave" }, {
      buffer = bufnr,
      group = augroup,
      callback = function(event)
        local diff_block = get_current_diff_block()
        if (event.event == "CursorMoved" or event.event == "CursorMovedI") and diff_block then
          show_keybinding_hint(diff_block.new_start_line)
        else
          vim.api.nvim_buf_clear_namespace(bufnr, KEYBINDING_NAMESPACE, 0, -1)
        end
      end,
    })
  end

  local confirm
  local has_rejected = false

  local function register_buf_write_events()
    vim.api.nvim_create_autocmd({ "BufWritePost" }, {
      buffer = bufnr,
      group = augroup,
      callback = function()
        if #diff_blocks ~= 0 then return end
        pcall(vim.api.nvim_del_augroup_by_id, augroup)
        if confirm then confirm:close() end
        if has_rejected then
          on_complete(false, "User canceled")
          return
        end
        if session_ctx then Helpers.mark_as_not_viewed(input.path, session_ctx) end
        on_complete(true, nil)
      end,
    })
  end

  local function register_keybinding_events()
    local keymap_opts = { buffer = bufnr }
    vim.keymap.set({ "n", "v" }, Config.mappings.diff.ours, function()
      if show_keybinding_hint_extmark_id then
        vim.api.nvim_buf_del_extmark(bufnr, KEYBINDING_NAMESPACE, show_keybinding_hint_extmark_id)
      end
      local diff_block, idx = get_current_diff_block()
      if not diff_block then return end
      pcall(vim.api.nvim_buf_del_extmark, bufnr, NAMESPACE, diff_block.delete_extmark_id)
      pcall(vim.api.nvim_buf_del_extmark, bufnr, NAMESPACE, diff_block.incoming_extmark_id)
      vim.api.nvim_buf_set_lines(
        bufnr,
        diff_block.new_start_line - 1,
        diff_block.new_end_line,
        false,
        diff_block.old_lines
      )
      diff_block.incoming_extmark_id = nil
      diff_block.delete_extmark_id = nil
      remove_diff_block(idx, false)
      local next_diff_block = get_next_diff_block()
      if next_diff_block then
        local winnr = Utils.get_winid(bufnr)
        vim.api.nvim_win_set_cursor(winnr, { next_diff_block.new_start_line, 0 })
        vim.api.nvim_win_call(winnr, function() vim.cmd("normal! zz") end)
      end
      has_rejected = true
    end, keymap_opts)

    vim.keymap.set({ "n", "v" }, Config.mappings.diff.theirs, function()
      if show_keybinding_hint_extmark_id then
        vim.api.nvim_buf_del_extmark(bufnr, KEYBINDING_NAMESPACE, show_keybinding_hint_extmark_id)
      end
      local diff_block, idx = get_current_diff_block()
      if not diff_block then return end
      pcall(vim.api.nvim_buf_del_extmark, bufnr, NAMESPACE, diff_block.incoming_extmark_id)
      pcall(vim.api.nvim_buf_del_extmark, bufnr, NAMESPACE, diff_block.delete_extmark_id)
      diff_block.incoming_extmark_id = nil
      diff_block.delete_extmark_id = nil
      remove_diff_block(idx, true)
      local next_diff_block = get_next_diff_block()
      if next_diff_block then
        local winnr = Utils.get_winid(bufnr)
        vim.api.nvim_win_set_cursor(winnr, { next_diff_block.new_start_line, 0 })
        vim.api.nvim_win_call(winnr, function() vim.cmd("normal! zz") end)
      end
    end, keymap_opts)

    vim.keymap.set({ "n", "v" }, Config.mappings.diff.next, function()
      if show_keybinding_hint_extmark_id then
        vim.api.nvim_buf_del_extmark(bufnr, KEYBINDING_NAMESPACE, show_keybinding_hint_extmark_id)
      end
      local diff_block = get_next_diff_block()
      if not diff_block then return end
      local winnr = Utils.get_winid(bufnr)
      vim.api.nvim_win_set_cursor(winnr, { diff_block.new_start_line, 0 })
      vim.api.nvim_win_call(winnr, function() vim.cmd("normal! zz") end)
    end, keymap_opts)

    vim.keymap.set({ "n", "v" }, Config.mappings.diff.prev, function()
      if show_keybinding_hint_extmark_id then
        vim.api.nvim_buf_del_extmark(bufnr, KEYBINDING_NAMESPACE, show_keybinding_hint_extmark_id)
      end
      local diff_block = get_prev_diff_block()
      if not diff_block then return end
      local winnr = Utils.get_winid(bufnr)
      vim.api.nvim_win_set_cursor(winnr, { diff_block.new_start_line, 0 })
      vim.api.nvim_win_call(winnr, function() vim.cmd("normal! zz") end)
    end, keymap_opts)
  end

  local function unregister_keybinding_events()
    pcall(vim.api.nvim_buf_del_keymap, bufnr, "n", Config.mappings.diff.ours)
    pcall(vim.api.nvim_buf_del_keymap, bufnr, "n", Config.mappings.diff.theirs)
    pcall(vim.api.nvim_buf_del_keymap, bufnr, "n", Config.mappings.diff.next)
    pcall(vim.api.nvim_buf_del_keymap, bufnr, "n", Config.mappings.diff.prev)
    pcall(vim.api.nvim_buf_del_keymap, bufnr, "v", Config.mappings.diff.ours)
    pcall(vim.api.nvim_buf_del_keymap, bufnr, "v", Config.mappings.diff.theirs)
    pcall(vim.api.nvim_buf_del_keymap, bufnr, "v", Config.mappings.diff.next)
    pcall(vim.api.nvim_buf_del_keymap, bufnr, "v", Config.mappings.diff.prev)
  end

  local function clear()
    if bufnr and not vim.api.nvim_buf_is_valid(bufnr) then return end
    vim.api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)
    vim.api.nvim_buf_clear_namespace(bufnr, KEYBINDING_NAMESPACE, 0, -1)
    unregister_keybinding_events()
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
  end

  local function insert_diff_blocks_new_lines()
    local base_line_ = 0
    for _, diff_block in ipairs(diff_blocks) do
      local start_line = diff_block.start_line + base_line_
      local end_line = diff_block.end_line + base_line_
      base_line_ = base_line_ + #diff_block.new_lines - #diff_block.old_lines
      vim.api.nvim_buf_set_lines(bufnr, start_line - 1, end_line, false, diff_block.new_lines)
    end
  end

  local function highlight_diff_blocks()
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    vim.api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)
    local base_line_ = 0
    local max_col = vim.o.columns
    for _, diff_block in ipairs(diff_blocks) do
      local start_line = diff_block.start_line + base_line_
      base_line_ = base_line_ + #diff_block.new_lines - #diff_block.old_lines
      local deleted_virt_lines = vim
        .iter(diff_block.old_lines)
        :map(function(line)
          --- append spaces to the end of the line
          local line_ = line .. string.rep(" ", max_col - #line)
          return { { line_, Highlights.TO_BE_DELETED_WITHOUT_STRIKETHROUGH } }
        end)
        :totable()
      local end_row = start_line + #diff_block.new_lines - 1
      local delete_extmark_id =
        vim.api.nvim_buf_set_extmark(bufnr, NAMESPACE, math.min(math.max(end_row - 1, 0), line_count - 1), 0, {
          virt_lines = deleted_virt_lines,
          hl_eol = true,
          hl_mode = "combine",
        })
      local incoming_extmark_id =
        vim.api.nvim_buf_set_extmark(bufnr, NAMESPACE, math.min(math.max(start_line - 1, 0), line_count - 1), 0, {
          hl_group = Highlights.INCOMING,
          hl_eol = true,
          hl_mode = "combine",
          end_row = end_row,
        })
      diff_block.delete_extmark_id = delete_extmark_id
      diff_block.incoming_extmark_id = incoming_extmark_id
    end
  end

  session_ctx.extmark_id_map = session_ctx.extmark_id_map or {}
  local extmark_id_map = session_ctx.extmark_id_map[opts.tool_use_id]
  if not extmark_id_map then
    extmark_id_map = {}
    session_ctx.extmark_id_map[opts.tool_use_id] = extmark_id_map
  end
  session_ctx.virt_lines_map = session_ctx.virt_lines_map or {}
  local virt_lines_map = session_ctx.virt_lines_map[opts.tool_use_id]
  if not virt_lines_map then
    virt_lines_map = {}
    session_ctx.virt_lines_map[opts.tool_use_id] = virt_lines_map
  end

  session_ctx.last_orig_diff_end_line_map = session_ctx.last_orig_diff_end_line_map or {}
  local last_orig_diff_end_line = session_ctx.last_orig_diff_end_line_map[opts.tool_use_id]
  if not last_orig_diff_end_line then
    last_orig_diff_end_line = 1
    session_ctx.last_orig_diff_end_line_map[opts.tool_use_id] = last_orig_diff_end_line
  end
  session_ctx.last_resp_diff_end_line_map = session_ctx.last_resp_diff_end_line_map or {}
  local last_resp_diff_end_line = session_ctx.last_resp_diff_end_line_map[opts.tool_use_id]
  if not last_resp_diff_end_line then
    last_resp_diff_end_line = 1
    session_ctx.last_resp_diff_end_line_map[opts.tool_use_id] = last_resp_diff_end_line
  end
  session_ctx.prev_diff_blocks_map = session_ctx.prev_diff_blocks_map or {}
  local prev_diff_blocks = session_ctx.prev_diff_blocks_map[opts.tool_use_id]
  if not prev_diff_blocks then
    prev_diff_blocks = {}
    session_ctx.prev_diff_blocks_map[opts.tool_use_id] = prev_diff_blocks
  end

  local function get_unstable_diff_blocks(diff_blocks_)
    local new_diff_blocks = {}
    for _, diff_block in ipairs(diff_blocks_) do
      local has = vim.iter(prev_diff_blocks):find(function(prev_diff_block)
        if prev_diff_block.start_line ~= diff_block.start_line then return false end
        if prev_diff_block.end_line ~= diff_block.end_line then return false end
        if #prev_diff_block.old_lines ~= #diff_block.old_lines then return false end
        if #prev_diff_block.new_lines ~= #diff_block.new_lines then return false end
        return true
      end)
      if has == nil then table.insert(new_diff_blocks, diff_block) end
    end
    return new_diff_blocks
  end

  local function highlight_streaming_diff_blocks()
    local unstable_diff_blocks = get_unstable_diff_blocks(diff_blocks)
    session_ctx.prev_diff_blocks_map[opts.tool_use_id] = diff_blocks
    local max_col = vim.o.columns
    for _, diff_block in ipairs(unstable_diff_blocks) do
      local new_lines = diff_block.new_lines
      local start_line = diff_block.start_line
      if #diff_block.old_lines > 0 then
        vim.api.nvim_buf_set_extmark(bufnr, NAMESPACE, start_line - 1, 0, {
          hl_group = Highlights.TO_BE_DELETED_WITHOUT_STRIKETHROUGH,
          hl_eol = true,
          hl_mode = "combine",
          end_row = start_line + #diff_block.old_lines - 1,
        })
      end
      if #new_lines == 0 then goto continue end
      local virt_lines = vim
        .iter(new_lines)
        :map(function(line)
          --- append spaces to the end of the line
          local line_ = line .. string.rep(" ", max_col - #line)
          return { { line_, Highlights.INCOMING } }
        end)
        :totable()
      local extmark_line
      if #diff_block.old_lines > 0 then
        extmark_line = math.max(0, start_line - 2 + #diff_block.old_lines)
      else
        extmark_line = math.max(0, start_line - 1 + #diff_block.old_lines)
      end
      -- Utils.debug("extmark_line", extmark_line, "idx", idx, "start_line", diff_block.start_line, "old_lines", table.concat(diff_block.old_lines, "\n"))
      local old_extmark_id = extmark_id_map[start_line]
      if old_extmark_id then vim.api.nvim_buf_del_extmark(bufnr, NAMESPACE, old_extmark_id) end
      local extmark_id = vim.api.nvim_buf_set_extmark(bufnr, NAMESPACE, extmark_line, 0, {
        virt_lines = virt_lines,
        hl_eol = true,
        hl_mode = "combine",
      })
      extmark_id_map[start_line] = extmark_id
      ::continue::
    end
  end

  if not is_streaming then
    insert_diff_blocks_new_lines()
    highlight_diff_blocks()
    register_cursor_move_events()
    register_keybinding_events()
    register_buf_write_events()
  else
    highlight_streaming_diff_blocks()
  end

  if diff_blocks[1] then
    if not vim.api.nvim_buf_is_valid(bufnr) then return false, "Code buffer is not valid" end
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    local winnr = Utils.get_winid(bufnr)
    if is_streaming then
      -- In streaming mode, focus on the last diff block
      local last_diff_block = diff_blocks[#diff_blocks]
      vim.api.nvim_win_set_cursor(winnr, { math.min(last_diff_block.start_line, line_count), 0 })
      vim.api.nvim_win_call(winnr, function() vim.cmd("normal! zz") end)
    else
      -- In normal mode, focus on the first diff block
      vim.api.nvim_win_set_cursor(winnr, { math.min(diff_blocks[1].new_start_line, line_count), 0 })
      vim.api.nvim_win_call(winnr, function() vim.cmd("normal! zz") end)
    end
  end

  if is_streaming then
    -- In streaming mode, don't show confirmation dialog, just apply changes
    return
  end

  pcall(vim.cmd.undojoin)

  confirm = Helpers.confirm("Are you sure you want to apply this modification?", function(ok, reason)
    clear()
    if not ok then
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, original_lines)
      on_complete(false, "User declined, reason: " .. (reason or "unknown"))
      return
    end
    local parent_dir = vim.fn.fnamemodify(abs_path, ":h")
    --- check if the parent dir is exists, if not, create it
    if vim.fn.isdirectory(parent_dir) == 0 then vim.fn.mkdir(parent_dir, "p") end
    if not vim.api.nvim_buf_is_valid(bufnr) then
      on_complete(false, "Code buffer is not valid")
      return
    end
    vim.api.nvim_buf_call(bufnr, function() vim.cmd("noautocmd write!") end)
    if session_ctx then Helpers.mark_as_not_viewed(input.path, session_ctx) end
    on_complete(true, nil)
  end, { focus = not Config.behaviour.auto_focus_on_diff_view }, session_ctx, M.name)
end

return M
