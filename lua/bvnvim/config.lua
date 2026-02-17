---@mod bvnvim.config Configuration module for bvnvim
---@brief [[
---Default configuration and validation for the bvnvim plugin.
---Handles all user-configurable options with sensible defaults.
---@brief ]]

local M = {}

---Default configuration values
---@class BvnvimConfig
---@field gt_root string Path to Gas Town root directory
---@field formulas_path string Path to formula definitions
---@field sessions_path string Path to Claude session transcripts
---@field default_rig? string Default rig to use (nil = auto-detect)
M.defaults = {
	gt_root = vim.fn.expand("~/gt"),
	formulas_path = vim.fn.expand("~/gt/.beads/formulas"),
	sessions_path = vim.fn.expand("~/.claude/projects"),
	default_rig = nil,
}

---Validate user configuration
---@param opts table User-provided options
---@return BvnvimConfig Validated configuration
function M.validate(opts)
	opts = opts or {}

	local config = vim.tbl_deep_extend("force", {}, M.defaults, opts)

	-- Validate gt_root exists or can be created
	if opts.gt_root and vim.fn.isdirectory(opts.gt_root) == 0 then
		vim.notify("bvnvim: gt_root does not exist: " .. opts.gt_root, vim.log.levels.WARN)
	end

	-- Validate formulas_path
	if opts.formulas_path and vim.fn.isdirectory(opts.formulas_path) == 0 then
		vim.notify("bvnvim: formulas_path does not exist: " .. opts.formulas_path, vim.log.levels.WARN)
	end

	-- Validate sessions_path
	if opts.sessions_path and vim.fn.isdirectory(opts.sessions_path) == 0 then
		vim.notify("bvnvim: sessions_path does not exist: " .. opts.sessions_path, vim.log.levels.WARN)
	end

	return config
end

return M
