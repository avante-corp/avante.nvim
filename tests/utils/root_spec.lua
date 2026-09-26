--- Worktrees vs the main checkout must not share a project identity.
---
--- Two Neovim instances (two tmux panes) — one in ~/nuon/nuon, one in a
--- worktree of that repo — used to resolve to the same Utils.root.get()
--- because LSP / .git follow the worktree pointer into the main repo. History,
--- latest_filename, and last_session.working_directory were then shared, so a
--- reply in the worktree appeared as the live thread in the other pane and
--- could `:cd` that pane into the worktree.

local Root = require("avante.utils.root")

local function mkdir(path) vim.fn.mkdir(path, "p") end

local function write(path, contents)
  local f = assert(io.open(path, "w"))
  f:write(contents)
  f:close()
end

local function real(path) return Root.realpath(path) or path end

describe("git worktree project identity", function()
  local tmp

  before_each(function()
    tmp = vim.fn.tempname()
    mkdir(tmp .. "/nuon/.git")
    mkdir(tmp .. "/worktrees/feature")
    write(tmp .. "/worktrees/feature/.git", "gitdir: " .. tmp .. "/nuon/.git/worktrees/feature\n")
  end)

  after_each(function() vim.fn.delete(tmp, "rf") end)

  it("finds a worktree by its .git file, not the main repo", function()
    local wt = Root.git_worktree_root(tmp .. "/worktrees/feature")
    assert.equals(real(tmp .. "/worktrees/feature"), wt)
  end)

  it("does not treat the main checkout as a worktree", function()
    assert.is_nil(Root.git_worktree_root(tmp .. "/nuon"))
  end)

  it("walks up from a subdirectory inside the worktree", function()
    mkdir(tmp .. "/worktrees/feature/pkg")
    local wt = Root.git_worktree_root(tmp .. "/worktrees/feature/pkg")
    assert.equals(real(tmp .. "/worktrees/feature"), wt)
  end)

  it("keeps a worktree's history off the main repo even when LSP points at it", function()
    local main = tmp .. "/nuon"
    local wt = tmp .. "/worktrees/feature"
    local resolved = Root.resolve_project_root(main, wt)
    assert.equals(real(wt), resolved)
  end)

  it("leaves the main checkout on the detected root", function()
    local main = tmp .. "/nuon"
    local resolved = Root.resolve_project_root(main, main)
    assert.equals(real(main), resolved)
  end)
end)

describe("should_follow_working_directory", function()
  local tmp

  before_each(function()
    tmp = vim.fn.tempname()
    mkdir(tmp .. "/nuon/.git")
    mkdir(tmp .. "/worktrees/feature")
    write(tmp .. "/worktrees/feature/.git", "gitdir: " .. tmp .. "/nuon/.git/worktrees/feature\n")
  end)

  after_each(function() vim.fn.delete(tmp, "rf") end)

  it("does not cd the main checkout into a worktree", function()
    assert.is_false(Root.should_follow_working_directory(tmp .. "/worktrees/feature", tmp .. "/nuon"))
  end)

  it("does not cd a worktree into the main checkout", function()
    assert.is_false(Root.should_follow_working_directory(tmp .. "/nuon", tmp .. "/worktrees/feature"))
  end)

  it("allows following a subdirectory of the same checkout", function()
    mkdir(tmp .. "/nuon/pkg")
    assert.is_true(Root.should_follow_working_directory(tmp .. "/nuon/pkg", tmp .. "/nuon"))
  end)

  it("is a no-op when already in that directory", function()
    assert.is_false(Root.should_follow_working_directory(tmp .. "/nuon", tmp .. "/nuon"))
  end)
end)
