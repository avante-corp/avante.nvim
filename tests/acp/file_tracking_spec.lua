--- Tracking which files an agent edited, for `/files`.
---
--- The update sequences below are copied verbatim from what
--- claude-agent-acp actually sends. The shape that matters: the opening
--- `tool_call` carries no path at all, and the updates that *do* carry the path
--- have no `status` field. Keying the snapshot on status therefore never
--- captured the "before" content, and every change diffed against empty.

local AcpThread = require("avante.acp_thread")

--- Drive a sequence of updates through the tracker, mirroring how llm.lua
--- merges each update into the stored tool call before tracking.
---@return {snapshots: string[], tracked: string[]}
local function replay(sequence)
  local thread = AcpThread:new({})
  local calls = { snapshots = {}, tracked = {} }

  local ctx = { file_snapshots = {}, edited_files = {}, edited_files_order = {} }
  local previous_avante = package.loaded["avante"]
  package.loaded["avante"] = { get = function() return { _current_session_ctx = ctx } end }

  local Helpers = require("avante.llm_tools.helpers")
  local real_snapshot, real_track = Helpers.snapshot_file_for_review, Helpers.track_edited_file
  local real_record = Helpers.record_file_snapshot
  Helpers.snapshot_file_for_review = function(path) table.insert(calls.snapshots, { path = path }) end
  Helpers.record_file_snapshot = function(path, _, content)
    table.insert(calls.snapshots, { path = path, content = content })
  end
  Helpers.track_edited_file = function(path) table.insert(calls.tracked, path) end

  local stored = nil
  for _, update in ipairs(sequence) do
    if not stored then
      stored = { acp_tool_call = vim.deepcopy(update) }
    else
      stored.acp_tool_call = vim.tbl_deep_extend("force", stored.acp_tool_call, update)
    end
    thread.tool_call_messages[update.toolCallId] = stored
    thread:_track_file_edit(update)
  end
  vim.wait(200)

  Helpers.snapshot_file_for_review, Helpers.track_edited_file = real_snapshot, real_track
  Helpers.record_file_snapshot = real_record
  package.loaded["avante"] = previous_avante
  return calls
end

local PATH = "/tmp/avante-track-test/sample.txt"

--- Exactly what claude-agent-acp emits for an Edit.
local function edit_sequence()
  return {
    { sessionUpdate = "tool_call", toolCallId = "t1", title = "Edit", kind = "edit", status = "pending", rawInput = {}, locations = {} },
    { sessionUpdate = "tool_call_update", toolCallId = "t1", title = "Edit " .. PATH, kind = "edit",
      rawInput = { file_path = PATH }, locations = { { path = PATH } } },
    { sessionUpdate = "tool_call_update", toolCallId = "t1", kind = "edit",
      rawInput = { file_path = PATH, old_string = "hello", new_string = "goodbye" },
      locations = { { path = PATH } } },
    { sessionUpdate = "tool_call_update", toolCallId = "t1", status = "completed" },
  }
end

describe("acp file tracking", function()
  it("snapshots the file before the edit completes", function()
    -- The regression: no snapshot meant /files diffed against an empty
    -- baseline and reported whole files as additions.
    local calls = replay(edit_sequence())

    assert.is_true(#calls.snapshots > 0, "no snapshot was taken before completion")
    assert.equals(PATH, calls.snapshots[1].path)
  end)

  it("records the file once the edit completes", function()
    local calls = replay(edit_sequence())

    assert.same({ PATH }, calls.tracked)
  end)

  it("snapshots strictly before tracking", function()
    local calls = replay(edit_sequence())

    assert.is_true(#calls.snapshots > 0 and #calls.tracked > 0)
  end)

  it("ignores read-only tools", function()
    local calls = replay({
      { sessionUpdate = "tool_call", toolCallId = "r1", title = "Read File", kind = "read", status = "pending", rawInput = {}, locations = {} },
      { sessionUpdate = "tool_call_update", toolCallId = "r1", kind = "read",
        rawInput = { file_path = PATH }, locations = { { path = PATH } } },
      { sessionUpdate = "tool_call_update", toolCallId = "r1", status = "completed" },
    })

    assert.same({}, calls.snapshots)
    assert.same({}, calls.tracked)
  end)

  it("tracks a Write even though the completion event carries no path", function()
    -- The terminal update has only {toolCallId, status}; the path must come
    -- from the merged tool call.
    local calls = replay({
      { sessionUpdate = "tool_call", toolCallId = "w1", title = "Write", kind = "edit", status = "pending", rawInput = {}, locations = {} },
      { sessionUpdate = "tool_call_update", toolCallId = "w1", kind = "edit", rawInput = { file_path = PATH } },
      { sessionUpdate = "tool_call_update", toolCallId = "w1", status = "completed" },
    })

    assert.same({ PATH }, calls.tracked)
  end)

  it("recognises write tools by title when kind is absent", function()
    local calls = replay({
      { sessionUpdate = "tool_call", toolCallId = "x1", title = "write_to_file", status = "pending",
        rawInput = { path = PATH } },
      { sessionUpdate = "tool_call_update", toolCallId = "x1", status = "completed" },
    })

    assert.same({ PATH }, calls.tracked)
  end)

  it("falls back to locations when rawInput has no path", function()
    local calls = replay({
      { sessionUpdate = "tool_call", toolCallId = "l1", title = "Edit", kind = "edit", status = "pending" },
      { sessionUpdate = "tool_call_update", toolCallId = "l1", kind = "edit", locations = { { path = PATH } } },
      { sessionUpdate = "tool_call_update", toolCallId = "l1", status = "completed" },
    })

    assert.same({ PATH }, calls.tracked)
  end)

  it("does nothing when no path is ever supplied", function()
    local calls = replay({
      { sessionUpdate = "tool_call", toolCallId = "n1", title = "Edit", kind = "edit", status = "pending" },
      { sessionUpdate = "tool_call_update", toolCallId = "n1", status = "completed" },
    })

    assert.same({}, calls.tracked)
  end)

  it("still records a failed edit so the change can be inspected", function()
    local calls = replay({
      { sessionUpdate = "tool_call", toolCallId = "f1", title = "Edit", kind = "edit", status = "pending" },
      { sessionUpdate = "tool_call_update", toolCallId = "f1", kind = "edit", rawInput = { file_path = PATH } },
      { sessionUpdate = "tool_call_update", toolCallId = "f1", status = "failed" },
    })

    assert.same({ PATH }, calls.tracked)
  end)
end)

describe("acp file tracking via diff content", function()
  --- Exactly what cursor-agent emits for an edit: rawInput and locations stay
  --- empty, the title is a bare "Edit File", and the path only ever appears
  --- inside the completed update's `diff` content.
  local function cursor_edit_sequence(path)
    return {
      {
        sessionUpdate = "tool_call",
        toolCallId = "c1",
        title = "Edit File",
        kind = "edit",
        status = "pending",
        rawInput = {},
      },
      { sessionUpdate = "tool_call_update", toolCallId = "c1", status = "in_progress" },
      {
        sessionUpdate = "tool_call_update",
        toolCallId = "c1",
        status = "completed",
        content = {
          {
            type = "diff",
            path = path,
            oldText = "line one\nline two\n",
            newText = "line one\nline TWO\n",
          },
        },
      },
    }
  end

  local PATH = "/tmp/avante-track-test/cursor.txt"

  it("tracks an edit whose path is only in the diff content", function()
    local calls = replay(cursor_edit_sequence(PATH))

    assert.same({ PATH }, calls.tracked)
  end)

  it("takes the before-content from the diff rather than the disk", function()
    -- The completed event arrives after the write, so there is no moment at
    -- which a filesystem snapshot would be correct.
    local calls = replay(cursor_edit_sequence(PATH))

    assert.equals(PATH, calls.snapshots[1] and calls.snapshots[1].path)
    assert.equals("line one\nline two\n", calls.snapshots[1] and calls.snapshots[1].content)
  end)

  it("still ignores read-only tools that carry content", function()
    local calls = replay({
      {
        sessionUpdate = "tool_call",
        toolCallId = "r1",
        title = "Read File",
        kind = "read",
        status = "pending",
      },
      {
        sessionUpdate = "tool_call_update",
        toolCallId = "r1",
        status = "completed",
        content = { { type = "diff", path = PATH, oldText = "a", newText = "b" } },
      },
    })

    assert.same({}, calls.tracked)
  end)

  it("prefers an explicit rawInput path over the diff path", function()
    local calls = replay({
      {
        sessionUpdate = "tool_call",
        toolCallId = "m1",
        title = "Edit",
        kind = "edit",
        status = "pending",
        rawInput = { file_path = "/tmp/explicit.txt" },
      },
      {
        sessionUpdate = "tool_call_update",
        toolCallId = "m1",
        status = "completed",
        content = { { type = "diff", path = "/tmp/from-diff.txt", oldText = "a", newText = "b" } },
      },
    })

    assert.same({ "/tmp/explicit.txt" }, calls.tracked)
  end)

  it("ignores diff entries with no path", function()
    local calls = replay({
      { sessionUpdate = "tool_call", toolCallId = "n1", title = "Edit", kind = "edit", status = "pending" },
      {
        sessionUpdate = "tool_call_update",
        toolCallId = "n1",
        status = "completed",
        content = { { type = "diff", oldText = "a", newText = "b" } },
      },
    })

    assert.same({}, calls.tracked)
  end)
end)
