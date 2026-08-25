--- Which ACP providers the new-chat picker offers.
---
--- `Config.acp_providers` is a deep merge with avante's built-in table, so it
--- always names every agent avante knows about -- including ones with no binary
--- installed. The picker must offer only what the user's config declares.

local Config = require("avante.config")

describe("config acp provider declarations", function()
  after_each(function() Config.setup({}) end)

  it("records only the providers the config declares", function()
    Config.setup({
      acp_providers = {
        ["my-agent"] = { command = "my-agent", args = { "acp" } },
        ["other"] = { command = "other" },
      },
    })

    assert.same({ "my-agent", "other" }, Config._user_acp_provider_names)
  end)

  it("still merges the built-ins into acp_providers", function()
    -- Declaring one provider must not remove the rest; only the *picker* is
    -- filtered, so a template or config can still name a built-in.
    Config.setup({ acp_providers = { ["my-agent"] = { command = "my-agent" } } })

    assert.is_not_nil(Config.acp_providers["my-agent"])
    assert.is_not_nil(Config.acp_providers["claude-code"])
  end)

  it("is empty when the config declares none", function()
    Config.setup({})

    assert.same({}, Config._user_acp_provider_names)
  end)

  it("sorts names so the picker order is stable", function()
    Config.setup({
      acp_providers = {
        zeta = { command = "z" },
        alpha = { command = "a" },
        mid = { command = "m" },
      },
    })

    assert.same({ "alpha", "mid", "zeta" }, Config._user_acp_provider_names)
  end)

  it("lets a declaration override a built-in without duplicating it", function()
    Config.setup({ acp_providers = { ["claude-code"] = { command = "my-claude" } } })

    assert.same({ "claude-code" }, Config._user_acp_provider_names)
    assert.equals("my-claude", Config.acp_providers["claude-code"].command)
  end)
end)
