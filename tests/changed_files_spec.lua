--- The /files quickfix list.
---
--- It used to emit one entry per diff hunk, every one labelled with the same
--- path, so a file edited in five places appeared five times. One entry per
--- file, positioned at the first edit, is what you actually want to navigate.

local ChangedFiles = require("avante.changed_files")

local function write(path, lines)
  vim.fn.writefile(lines, path)
  return path
end

--- Build a session_ctx the way llm_tools.helpers does.
local function ctx(entries)
  local snapshots, order = {}, {}
  for _, entry in ipairs(entries) do
    snapshots[entry.path] = entry.before
    table.insert(order, entry.path)
  end
  return { file_snapshots = snapshots, edited_files_order = order }
end

describe("changed_files quickfix", function()
  local tmp

  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    vim.fn.setqflist({}, "r")
  end)

  after_each(function()
    vim.fn.delete(tmp, "rf")
    vim.fn.setqflist({}, "r")
  end)

  it("emits one entry for a file edited in several places", function()
    -- Three separate hunks in one file: previously three identical-looking rows.
    local before = {}
    for i = 1, 40 do
      before[i] = "line " .. i
    end
    local after = vim.deepcopy(before)
    after[2] = "CHANGED 2"
    after[20] = "CHANGED 20"
    after[38] = "CHANGED 38"

    local path = write(tmp .. "/multi.txt", after)
    ChangedFiles._refresh_qflist(ctx({ { path = path, before = table.concat(before, "\n") } }))

    local items = vim.fn.getqflist()
    assert.equals(1, #items)
  end)

  it("points at the first edit in the file", function()
    local before = {}
    for i = 1, 30 do
      before[i] = "line " .. i
    end
    local after = vim.deepcopy(before)
    after[7] = "CHANGED"
    after[25] = "ALSO CHANGED"

    local path = write(tmp .. "/first.txt", after)
    ChangedFiles._refresh_qflist(ctx({ { path = path, before = table.concat(before, "\n") } }))

    assert.equals(7, vim.fn.getqflist()[1].lnum)
  end)

  it("totals additions and deletions across every hunk", function()
    local before = { "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l" }
    local after = vim.deepcopy(before)
    after[2] = "B"
    after[11] = "K"

    local path = write(tmp .. "/totals.txt", after)
    ChangedFiles._refresh_qflist(ctx({ { path = path, before = table.concat(before, "\n") } }))

    local text = vim.fn.getqflist()[1].text
    assert.is_not_nil(text:find("+2 -2", 1, true), "expected combined counts, got: " .. text)
  end)

  it("lists each edited file once", function()
    local one = write(tmp .. "/one.txt", { "new one" })
    local two = write(tmp .. "/two.txt", { "new two" })

    ChangedFiles._refresh_qflist(ctx({
      { path = one, before = "old one" },
      { path = two, before = "old two" },
    }))

    assert.equals(2, #vim.fn.getqflist())
  end)

  it("de-duplicates a file recorded twice", function()
    -- track_edited_file guards against this, but a path can still arrive under
    -- two spellings.
    local path = write(tmp .. "/dup.txt", { "changed" })
    local context = ctx({ { path = path, before = "original" } })
    table.insert(context.edited_files_order, path)

    ChangedFiles._refresh_qflist(context)

    assert.equals(1, #vim.fn.getqflist())
  end)

  it("skips a file whose content is unchanged", function()
    local path = write(tmp .. "/same.txt", { "identical" })

    ChangedFiles._refresh_qflist(ctx({ { path = path, before = "identical" } }))

    assert.equals(0, #vim.fn.getqflist())
  end)

  it("reports a new file as pure additions", function()
    -- No snapshot means the file did not exist before the agent wrote it.
    local path = write(tmp .. "/created.txt", { "one", "two" })

    ChangedFiles._refresh_qflist({ file_snapshots = {}, edited_files_order = { path } })

    local items = vim.fn.getqflist()
    assert.equals(1, #items)
    assert.is_not_nil(items[1].text:find("-0", 1, true))
  end)

  it("counts files, not hunks, in the title", function()
    local before = {}
    for i = 1, 30 do
      before[i] = "line " .. i
    end
    local after = vim.deepcopy(before)
    after[3] = "X"
    after[27] = "Y"

    local path = write(tmp .. "/title.txt", after)
    ChangedFiles._refresh_qflist(ctx({ { path = path, before = table.concat(before, "\n") } }))

    local title = vim.fn.getqflist({ title = 1 }).title
    assert.is_not_nil(title:find("1 file", 1, true), "got: " .. tostring(title))
  end)

  it("tolerates a file that has since been deleted", function()
    ChangedFiles._refresh_qflist(ctx({ { path = tmp .. "/gone.txt", before = "had content" } }))

    -- Deleted counts as changed, so it is still worth listing.
    assert.is_true(#vim.fn.getqflist() <= 1)
  end)

  it("handles an empty session", function()
    ChangedFiles._refresh_qflist({})

    assert.equals(0, #vim.fn.getqflist())
  end)
end)

describe("changed_files newline handling", function()
  local tmp

  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    vim.fn.setqflist({}, "r")
  end)

  after_each(function()
    vim.fn.delete(tmp, "rf")
    vim.fn.setqflist({}, "r")
  end)

  it("does not invent a deletion when the snapshot ends in a newline", function()
    -- Agents hand back the previous text with its trailing newline; appending
    -- another made every diff report one extra deleted line.
    local path = tmp .. "/nl.txt"
    vim.fn.writefile({ "alpha", "BRAVO", "charlie", "DELTA" }, path)

    require("avante.changed_files")._refresh_qflist({
      file_snapshots = { [path] = "alpha\nbravo\ncharlie\ndelta\n" },
      edited_files_order = { path },
    })

    local text = vim.fn.getqflist()[1].text
    assert.is_not_nil(text:find("+2 -2", 1, true), "expected +2 -2, got: " .. text)
  end)

  it("gives the same counts with or without a trailing newline", function()
    local path = tmp .. "/nl2.txt"
    vim.fn.writefile({ "one", "TWO" }, path)
    local CF = require("avante.changed_files")

    CF._refresh_qflist({ file_snapshots = { [path] = "one\ntwo\n" }, edited_files_order = { path } })
    local with_newline = vim.fn.getqflist()[1].text

    CF._refresh_qflist({ file_snapshots = { [path] = "one\ntwo" }, edited_files_order = { path } })
    local without_newline = vim.fn.getqflist()[1].text

    assert.equals(with_newline, without_newline)
  end)
end)
