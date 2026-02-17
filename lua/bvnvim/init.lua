---@mod bvnvim.init Main entry point for bvnvim plugin
---@brief [[
---bvnvim: Neovim Beads Viewer/Editor Plugin
---
---A Neovim plugin for viewing and editing beads (issues) from the Gas Town
---workflow system. Provides three content planes:
---  1. Agent Session Transcripts (JSONL logs)
---  2. Formulas (workflow definitions from Dolt)
---  3. Materialized Beads (issues from Dolt)
---
---Commands:
---  :Beads list              - List beads in current rig
---  :Beads show <id>         - Show bead detail
---  :Beads formula [name]    - Browse/view formulas
---  :Beads session [uuid]    - View session transcripts
---  :Beads wizard start|stop - Toggle wizard mode
---  :Beads triage [rig]      - Open triage diff view
---  :Beads refresh           - Refresh beads cache
---@brief ]]

local config = require("bvnvim.config")
local highlight = require("bvnvim.highlight")

---@class BvnvimState
---@field config BvnvimConfig Validated configuration
---@field current_rig? string Currently selected rig
---@field beads_cache table<string, table> Cached bead data
---@field formula_cache table<string, table> Cached formula data
---@field session_index table<string, table> Session metadata index
---@field buffers table<string, number> Active buffer handles

---@class Bvnvim
---@field state BvnvimState Plugin state table
local M = {}

---Plugin state - all mutable state lives here
M.state = {
	config = {},
	current_rig = nil,
	beads_cache = {},
	formula_cache = {},
	session_index = {},
	buffers = {},
}

---Setup the plugin with user configuration
---@param opts? table User configuration options
function M.setup(opts)
	-- Validate and store configuration
	M.state.config = config.validate(opts)

	-- Auto-detect current rig if possible
	M.state.current_rig = M._detect_rig()

	-- Initialize highlight groups
	highlight.init()
	-- Register commands
	M._register_commands()

	vim.notify("bvnvim: initialized", vim.log.levels.INFO)
end

---Auto-detect the current rig from git remote or directory
---@return string|nil Rig name or nil if not detected
function M._detect_rig()
	-- Try to detect from git remote
	local handle = io.popen("git remote get-url origin 2>/dev/null")
	if handle then
		local remote = handle:read("*l")
		handle:close()
		if remote then
			-- Extract repo name from remote URL
			local repo = remote:match("/([^/]+)%.git$") or remote:match("/([^/]+)$")
			if repo then
				return repo
			end
		end
	end

	-- Try to detect from current directory name
	local cwd = vim.fn.getcwd()
	local dirname = cwd:match("([^/]+)$")
	if dirname then
		return dirname
	end

	return nil
end

---Register all :Beads commands
function M._register_commands()
	vim.api.nvim_create_user_command("Beads", function(opts)
		M._cmd_beads(opts)
	end, {
		nargs = "*",
		complete = M._complete_beads,
		desc = "bvnvim: Beads viewer and editor",
	})
end

---Main Beads command handler
---@param opts table Command options from nvim_create_user_command
function M._cmd_beads(opts)
	local args = vim.split(opts.args, "%s+")
	local subcmd = args[1] or "list"

	if subcmd == "list" then
		M.cmd_list()
	elseif subcmd == "show" then
		M.cmd_show(args[2])
	elseif subcmd == "formula" then
		M.cmd_formula(args[2])
	elseif subcmd == "session" then
		M.cmd_session(args[2])
	elseif subcmd == "wizard" then
		M.cmd_wizard(args[2])
	elseif subcmd == "triage" then
		M.cmd_triage(args[2])
	elseif subcmd == "refresh" then
		M.cmd_refresh()
	else
		vim.notify("bvnvim: unknown subcommand: " .. subcmd, vim.log.levels.ERROR)
	end
end

---Command completion for :Beads
---@param arg_lead string Current argument being typed
---@param cmd_line string Full command line
---@param cursor_pos number Cursor position
---@return string[] Completion candidates
function M._complete_beads(arg_lead, cmd_line, cursor_pos)
	local subcmds = { "list", "show", "formula", "session", "wizard", "triage", "refresh" }
	local words = vim.split(cmd_line:sub(1, cursor_pos), "%s+")

	if #words <= 2 then
		-- Complete subcommand
		return vim.tbl_filter(function(cmd)
			return vim.startswith(cmd, arg_lead)
		end, subcmds)
	end

	-- Subcommand-specific completion
	local subcmd = words[2]
	if subcmd == "wizard" then
		return vim.tbl_filter(function(opt)
			return vim.startswith(opt, arg_lead)
		end, { "start", "stop" })
	end

	return {}
end

---List beads in current rig
function M.cmd_list()
	vim.notify("bvnvim: list - not yet implemented", vim.log.levels.INFO)
	-- TODO: Open beads list buffer (bv-lj7)
end

---Show bead detail
---@param bead_id? string Bead ID to show
function M.cmd_show(bead_id)
	if not bead_id then
		vim.notify("bvnvim: show requires a bead ID", vim.log.levels.ERROR)
		return
	end
	vim.notify("bvnvim: show " .. bead_id .. " - not yet implemented", vim.log.levels.INFO)
	-- TODO: Open bead detail buffer (bv-lj7)
end

---Browse or view formulas
---@param formula_name? string Specific formula to view
function M.cmd_formula(formula_name)
	if formula_name then
		vim.notify("bvnvim: formula " .. formula_name .. " - not yet implemented", vim.log.levels.INFO)
		-- TODO: Open formula detail buffer (bv-kak)
	else
		vim.notify("bvnvim: formula list - not yet implemented", vim.log.levels.INFO)
		-- TODO: Open formula list buffer (bv-kak)
	end
end

---View session transcripts
---@param session_uuid? string Specific session to view
function M.cmd_session(session_uuid)
	if session_uuid then
		vim.notify("bvnvim: session " .. session_uuid .. " - not yet implemented", vim.log.levels.INFO)
		-- TODO: Open session transcript buffer (bv-40e)
	else
		vim.notify("bvnvim: session list - not yet implemented", vim.log.levels.INFO)
		-- TODO: Open session list buffer (bv-40e)
	end
end

---Toggle wizard mode
---@param action? string "start" or "stop"
function M.cmd_wizard(action)
	if action == "start" then
		vim.notify("bvnvim: wizard mode started", vim.log.levels.INFO)
		-- TODO: Enable wizard mode (bv-c7s)
	elseif action == "stop" then
		vim.notify("bvnvim: wizard mode stopped", vim.log.levels.INFO)
		-- TODO: Disable wizard mode (bv-c7s)
	else
		vim.notify("bvnvim: wizard requires 'start' or 'stop'", vim.log.levels.ERROR)
	end
end

---Open triage diff view
---@param rig_name? string Rig to triage (defaults to current)
function M.cmd_triage(rig_name)
	rig_name = rig_name or M.state.current_rig
	if not rig_name then
		vim.notify("bvnvim: triage requires a rig name (could not auto-detect)", vim.log.levels.ERROR)
		return
	end
	vim.notify("bvnvim: triage " .. rig_name .. " - not yet implemented", vim.log.levels.INFO)
	-- TODO: Open triage diff buffer (bv-e39)
end

---Refresh all caches
function M.cmd_refresh()
	M.state.beads_cache = {}
	M.state.formula_cache = {}
	M.state.session_index = {}
	vim.notify("bvnvim: caches refreshed", vim.log.levels.INFO)
end

return M
