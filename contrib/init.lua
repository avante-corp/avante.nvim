vim.g.avante = {
  -- triggers issue in docker ?
  -- log_level = vim.log_level.DEBUG,
  rag_service = { enabled = false, runner = "native" },
  provider = "inspect",
  providers = {
    inspect = {
      __inherited_from = "openai",
      endpoint = "http://localhost:13131/v1",
      model = "inspect",
      api_key_name = "",
    },
  },
  file_selector = { provider = "fzf_lua" },
  ui = { border = "single", background_color = "#FF0000" },
  selector = {
    provider = "fzf_lua",
  },
}
require("avante").setup()
