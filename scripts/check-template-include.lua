-- Run from the repository root: nvim --headless -u NONE -l scripts/check-template-include.lua
package.cpath = "./lua/?.so;" .. package.cpath
local templates = require("avante_templates")
local dir = vim.fn.tempname()
vim.fn.mkdir(dir .. "/templates", "p")
vim.fn.writefile({ "outside cwd" }, dir .. "/foreign.jinja", "b")
vim.fn.writefile({ '{% include "' .. dir .. '/foreign.jinja" %}' }, dir .. "/templates/main.jinja", "b")
templates.initialize(dir .. "/templates", vim.fn.getcwd())
local ok, result = pcall(templates.render, "main.jinja", { ask = true, code_lang = "lua" })
vim.fn.delete(dir, "rf")
assert(ok, result)
assert(result == "outside cwd", result)
print("PASS: included an absolute path outside cwd and both template roots")
