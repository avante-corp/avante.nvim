---@meta

---@alias avante.PathCopyResults table<Path, boolean|avante.PathCopyResults>

-- Plenary's chainable path methods do not declare their return types.
---@class Path
---@field filename string
---@field new fun(self: Path, ...: string|Path): Path
---@field joinpath fun(self: Path, ...: string|Path): Path
---@field parent fun(self: Path): Path
---@field read fun(self: Path): string
