describe("ChatGPT subscription commands", function()
  for _, action in ipairs({ "login", "logout" }) do
    it("dispatches " .. action .. " through the Rust client", function()
      require("avante.commands").setup()
      local auth = stub(require("avante.libs.rig_client"), "chatgpt_auth")
      local ok, err = pcall(vim.cmd, "Avante chatgpt " .. action)
      auth:revert()
      assert.is_true(ok, err)
      assert.stub(auth).was_called_with(action)
    end)
  end
end)
