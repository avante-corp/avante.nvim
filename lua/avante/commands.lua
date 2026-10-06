---@mod avante-commands Commands (:AvanteAsk,...)
---
---@brief [[
---
--- Commands
---
---                                                     *:Avante*
--- :Avante rag start
---         Start the configured RAG service and index the current project.
--- :Avante rag stop
---         Stop the configured RAG service.
--- :Avante rag status
---         Report whether the RAG service is healthy.
--- :Avante rag query [text...]
---         Query the current project. All text after query is used literally.
---         Without text, prompt for a query. Show the answer and source paths
---         in a Markdown scratch split. Example:
--->
---         :Avante rag query How does authentication work?
---<
--- :Avante acp modes
---         Switch ACP mode.
--- :Avante acp sessions
---         List the current ACP agent's sessions for this project, including
---         ones started outside avante (e.g. in the agent's CLI), and resume
---         the selected one in the sidebar. Listing requires `session/list`;
---         importing the selected session's history also requires `session/load`.
---
---         Use :Avante --help, :Avante rag --help or :Avante acp --help for
---         generated help.
---
---                                                     *:AvanteAsk*
--- :AvanteAsk [question] [position=left|right|top|bottom] [ask=true|false]
---         Ask AI about your code. Example:
--->
---         :AvanteAsk position=right Refactor this function
---<
---
---                                                     *:AvanteChat*
--- :AvanteChat [args]
---         Start a chat session with AI about your codebase.
---
---                                                     *:AvanteChatNew*
--- :AvanteChatNew [args]
---         Start a new chat session.
---
---                                                     *:AvanteHistory*
--- :AvanteHistory
---         Open a picker for previous chat sessions.
---
---                                                     *:AvanteClear*
--- :AvanteClear [history|cache]
---         Clear the current chat history or Avante cache.
---
---                                                     *:AvanteBuild*
--- :AvanteBuild [source=true|false]
---         Build dependencies for the project.
---
---                                                     *:AvanteEdit*
--- :[range]AvanteEdit [instruction]
---         Edit the selected code blocks or range.
---
---                                                     *:AvanteFocus*
--- :AvanteFocus
---         Switch focus to or from the sidebar.
---
---                                                     *:AvanteRefresh*
--- :AvanteRefresh
---         Refresh all Avante windows.
---
---                                                     *:AvanteStop*
--- :AvanteStop
---         Stop the current AI request.
---
---                                                     *:AvanteSwitchProvider*
--- :AvanteSwitchProvider [--save] [--acp {true|false}] [filter]
---         Switch AI provider. Pass `--save` to restore the choice on startup,
---         overriding the configured default provider. Without it, the switch
---         only affects the current session. ACP providers are included by default; pass `--acp false` to hide them.
---         The optional filter prefills the selector input without removing providers.
---
---                                                     *:AvanteSwitchSelectorProvider*
--- :AvanteSwitchSelectorProvider {provider}
---         Switch selector provider.
---
---                                                     *:AvanteSwitchInputProvider*
--- :AvanteSwitchInputProvider {native|dressing|snacks}
---         Switch input provider.
---
---                                                     *:AvanteShowRepoMap*
--- :AvanteShowRepoMap
---         Show the repository map for the project.
---
---                                                     *:AvanteToggle*
--- :AvanteToggle
---         Toggle the Avante sidebar.
---
---                                                     *:AvanteModels*
--- :AvanteModels [--all] [timeout]
---         Show the model list, optionally querying all providers and overriding
---         the model-list timeout in milliseconds. See |avante-api.select_model|
---
---                                                     *:AvanteACPModels*
--- :AvanteACPModels
---         Switch ACP model.
---
---                                                     *:AvanteACPModes*
--- :AvanteACPModes
---         Deprecated alias for :Avante acp modes. Shows a deprecation warning.
---
---@brief ]]

local M = {}

local function query_rag(text)
  local Utils = require("avante.utils")
  if vim.trim(text) == "" then
    vim.ui.input({ prompt = "RAG query: " }, function(input)
      if input and vim.trim(input) ~= "" then query_rag(input) end
    end)
    return
  end

  local uri = "file://" .. Utils.get_project_root()
  if uri:sub(-1) ~= "/" then uri = uri .. "/" end
  require("avante.rag_service").retrieve(
    uri,
    text,
    vim.schedule_wrap(function(response, err)
      if err or not response then
        Utils.error("RAG query failed: " .. (err or "No response"))
        return
      end

      local lines = vim.split(response.response or "", "\n", { plain = true })
      if response.sources and #response.sources > 0 then
        vim.list_extend(lines, { "", "## Sources", "" })
        for _, source in ipairs(response.sources) do
          table.insert(lines, "- " .. source.uri)
        end
      end
      local buffer = vim.api.nvim_create_buf(false, true)
      vim.bo[buffer].bufhidden = "wipe"
      vim.bo[buffer].swapfile = false
      vim.bo[buffer].filetype = "markdown"
      vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
      vim.bo[buffer].modifiable = false
      vim.cmd("botright split")
      vim.api.nvim_win_set_buf(0, buffer)
    end)
  )
end

---Register the top-level Avante command.
function M.setup()
  local cmdparse = require("mega.cmdparse")
  local parser = cmdparse.ParameterParser.new({ name = "Avante", help = "Avante commands" })
  local subparsers = parser:add_subparsers({ destination = "command" })
  local rag = subparsers:add_parser({ name = "rag", help = "Manage and query the RAG service" })
  local actions = rag:add_subparsers({ destination = "rag_command" })

  actions:add_parser({ name = "start", help = "Start RAG and index the current project" }):set_execute(function()
    local service = require("avante.rag_service")
    if service.is_ready() then
      require("avante.utils").info("RAG service is running")
    else
      -- todo forward extra args to start command or
      -- we should probably add rag_providers
      service.run_rag_service()
    end
  end)
  actions
    :add_parser({ name = "stop", help = "Stop the RAG service" })
    :set_execute(function() require("avante.rag_service").stop_rag_service() end)
  actions:add_parser({ name = "status", help = "Check RAG service health" }):set_execute(function()
    local ready = require("avante.rag_service").is_ready()
    require("avante.utils").info(ready and "RAG service is running" or "RAG service is not ready or unreachable")
  end)
  local query = actions:add_parser({ name = "query", help = "Query the current project; omit text to prompt" })
  query:add_parameter({ name = "text", nargs = cmdparse.REMAINDER, required = false, help = "Query text" })
  query:set_execute(function(data) query_rag(data.namespace.text or "") end)

  local acp = subparsers:add_parser({ name = "acp", help = "Work with the current ACP agent" })
  local acp_actions = acp:add_subparsers({ destination = "acp_command" })
  acp_actions
    :add_parser({ name = "modes", help = "Switch ACP mode" })
    :set_execute(function() require("avante.api").select_acp_mode() end)
  acp_actions
    :add_parser({ name = "sessions", help = "List the agent's sessions for this project and resume one" })
    :set_execute(function() require("avante.api").select_acp_session() end)

  local execute = cmdparse.make_parser_triager(function() return parser end)
  -- cmdparse annotates command options here, but its callback receives command arguments.
  ---@cast execute fun(options: vim.api.keyset.create_user_command.command_args)
  vim.api.nvim_create_user_command("Avante", function(opts)
    -- cmdparse needs a separator for literal remainder text. Insert it internally
    -- so users can type questions containing quotes or flags without escaping.
    opts.args = opts.args:gsub("^(%s*rag%s+query)%s+(.*)$", "%1 -- %2", 1)
    execute(opts)
  end, {
    nargs = "*",
    desc = "Avante commands",
    complete = cmdparse.make_parser_completer(function() return parser end),
  })
end

return M
