local stub = require("luassert.stub")
local ACPClient = require("avante.libs.acp_client")
local Config = require("avante.config")
local Llm = require("avante.llm")

describe("ACP writes through file aliases", function()
  local dir, real, alias, buf, client, handlers, new_stub, provider, providers, ask_opts, behaviour

  before_each(function()
    provider, providers = Config.provider, Config.acp_providers
    ask_opts, behaviour = Config.ask_opts, Config.behaviour
    Config.ask_opts, Config.behaviour = {}, Config.behaviour or {}
    Config.provider = "test-acp"
    Config.acp_providers = { ["test-acp"] = { command = "unused" } }
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    real, alias = dir .. "/real.txt", dir .. "/alias.txt"
    vim.fn.writefile({ "on disk" }, real)
    -- Neovim's timestamp check must see a change even on filesystems with coarse timestamps.
    assert(vim.uv.fs_utime(real, os.time() - 5, os.time() - 5))
    assert(vim.uv.fs_symlink(real, alias))
    vim.cmd.edit(vim.fn.fnameescape(alias))
    buf = vim.api.nvim_get_current_buf()
    client = { connect = function() end }
    new_stub = stub(ACPClient, "new").invokes(function(_, config)
      handlers = config.handlers
      return client
    end)
    Llm._stream_acp({ on_save_acp_client = function() return true end })
  end)

  after_each(function()
    if client and client.on_dispose then client.on_dispose() end
    if new_stub then new_stub:revert() end
    Config.provider, Config.acp_providers = provider, providers
    Config.ask_opts, Config.behaviour = ask_opts, behaviour
    if buf and vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
    if dir then vim.fn.delete(dir, "rf") end
  end)

  it("preserves disk and unsaved edits in a buffer opened through a symlink", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved user changes" })
    local write_error
    handlers.on_write_file(assert(vim.uv.fs_realpath(alias)), "agent replacement", function(err) write_error = err end)

    assert.matches("unsaved changes", write_error)
    assert.same({ "on disk" }, vim.fn.readfile(real))
    assert.same({ "unsaved user changes" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.is_true(vim.bo[buf].modified)
  end)

  it("rejects a write to an unsaved buffer through a symlinked directory", function()
    vim.fn.mkdir(dir .. "/nested", "p")
    assert(vim.uv.fs_symlink(dir .. "/nested", dir .. "/alias-dir"))
    local path = dir .. "/alias-dir/new.txt"
    vim.api.nvim_buf_set_name(buf, path)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved user changes" })
    local write_error

    handlers.on_write_file(path, "agent replacement", function(err) write_error = err end)

    assert.matches("unsaved changes", write_error)
    assert.is_nil(vim.uv.fs_stat(path))
    assert.same({ "unsaved user changes" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.is_true(vim.bo[buf].modified)
  end)

  it("refreshes an unmodified buffer opened through a symlink", function()
    vim.bo[buf].autoread = true
    local called, write_error = false, nil
    vim.schedule(function()
      handlers.on_write_file(assert(vim.uv.fs_realpath(alias)), "agent replacement\n", function(err)
        called, write_error = true, err
      end)
    end)

    assert.is_true(vim.wait(500, function() return called end, 5))
    assert.is_nil(write_error)
    assert.same({ "agent replacement" }, vim.fn.readfile(real))
    assert.same({ "agent replacement" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.is_false(vim.bo[buf].modified)
  end)
end)
