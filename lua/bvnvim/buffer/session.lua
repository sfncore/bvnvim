---@mod bvnvim.buffer.session Session transcript buffer
---@brief [[
---Read-only buffer showing a Claude Code session transcript.
---
---Buffer URI: session://<uuid>
---buftype:     nofile (read-only)
---
---Format (markdown-ish with collapsible sections):
---  ## User _08:30_
---
---  Message text here.
---
---  ## Claude _08:31_
---
---  Response text here.
---
---  > **Tool: bash** [fold marker]
---  > command output
---
---Highlight groups:
---  BvnvimHuman    — user turns (green, bold)
---  BvnvimAgent    — assistant turns (blue)
---  BvnvimTool     — tool call sections (gray, italic)
---
---Keymaps:
---  q      close buffer
---  r      reload transcript from disk
---  zo/zc  open/close folds (tool call sections)
---  gg/G   jump to first/last turn
---@brief ]]

local sessions_data = require("bvnvim.data.sessions")
local highlight     = require("bvnvim.highlight")

local M = {}

---Get or create a buffer for a session UUID
---@param uuid string
---@return number bufnr
local function get_or_create_buf(uuid)
	local name     = "session://" .. uuid
	local existing = vim.fn.bufnr(name)
	if existing ~= -1 then
		return existing
	end
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(bufnr, name)
	return bufnr
end

---Find the JSONL path for a session UUID.
---Searches ~/.claude/projects/ directories.
---@param uuid string Session UUID
---@return string|nil path
local function find_session_path(uuid)
	local ok, bvnvim = pcall(require, "bvnvim")
	local sessions_root = "~/.claude/projects"
	if ok and bvnvim.state and bvnvim.state.config then
		sessions_root = bvnvim.state.config.sessions_path or sessions_root
	end
	sessions_root = vim.fn.expand(sessions_root)

	-- Search for <uuid>.jsonl in project subdirs
	local found = vim.fn.glob(sessions_root .. "/*/" .. uuid .. ".jsonl", false, true)
	if #found > 0 then
		return found[1]
	end
	-- Also check flat layout
	local flat = sessions_root .. "/" .. uuid .. ".jsonl"
	if vim.fn.filereadable(flat) == 1 then
		return flat
	end
	return nil
end

---Apply extmark highlights to rendered transcript lines.
---@param bufnr number
---@param lines string[] Buffer lines
local function apply_highlights(bufnr, lines)
	highlight.clear_extmarks(bufnr)
	for i, line in ipairs(lines) do
		local row = i - 1 -- 0-indexed
		if line:match("^## User") then
			highlight.highlight_range(bufnr, row, 0, row, #line, "BvnvimHuman")
		elseif line:match("^## Claude") then
			highlight.highlight_range(bufnr, row, 0, row, #line, "BvnvimAgent")
		elseif line:match("^> %*%*Tool:") or line:match("^---$") then
			highlight.highlight_range(bufnr, row, 0, row, #line, "BvnvimTool")
		end
	end
end

---Set up folds so tool call blocks collapse automatically.
---Uses manual fold markers.
---@param bufnr number
---@param lines string[] Buffer lines
local function setup_folds(bufnr, lines)
	-- Fold lines that are ">" blockquote sections (tool sections)
	vim.api.nvim_set_option_value("foldmethod", "expr", { buf = bufnr })
	vim.api.nvim_set_option_value("foldexpr",
		"getline(v:lnum)=~'^> '?1:0", { buf = bufnr })
	vim.api.nvim_set_option_value("foldlevel", 1, { buf = bufnr })
end

---Set up keymaps for session buffer.
---@param bufnr number
---@param uuid string
---@param path string JSONL path
local function setup_keymaps(bufnr, uuid, path)
	local km_opts = { buffer = bufnr, silent = true, noremap = true }

	-- q: close
	vim.keymap.set("n", "q", function()
		vim.api.nvim_buf_delete(bufnr, { force = true })
	end, km_opts)

	-- r: reload
	vim.keymap.set("n", "r", function()
		M.open(uuid)
	end, km_opts)
end

---Open a session transcript buffer.
---@param uuid string Session UUID
function M.open(uuid)
	if not uuid or uuid == "" then
		vim.notify("bvnvim: session UUID required", vim.log.levels.ERROR)
		return
	end

	local path = find_session_path(uuid)
	if not path then
		vim.notify("bvnvim: session file not found for UUID: " .. uuid, vim.log.levels.ERROR)
		return
	end

	local markdown, err = sessions_data.extract_transcript(path)
	if err then
		vim.notify("bvnvim: error reading session " .. uuid .. ": " .. err, vim.log.levels.ERROR)
		return
	end

	local bufnr = get_or_create_buf(uuid)

	-- Buffer settings
	vim.api.nvim_set_option_value("buftype",    "nofile",          { buf = bufnr })
	vim.api.nvim_set_option_value("bufhidden",  "wipe",            { buf = bufnr })
	vim.api.nvim_set_option_value("swapfile",   false,             { buf = bufnr })
	vim.api.nvim_set_option_value("modifiable", true,              { buf = bufnr })
	vim.api.nvim_set_option_value("filetype",   "bvnvim-session",  { buf = bufnr })

	-- Write content
	local lines = vim.split(markdown, "\n", { plain = true })
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

	-- Open in current window
	vim.api.nvim_set_current_buf(bufnr)

	-- Highlights + folds + keymaps
	apply_highlights(bufnr, lines)
	setup_folds(bufnr, lines)
	setup_keymaps(bufnr, uuid, path)
end

---Open the most recent session for a given rig or bead.
---@param opts table Options: rig (string) or bead_id (string)
function M.open_latest(opts)
	opts = opts or {}
	local sessions = sessions_data.build_index()

	for _, session in ipairs(sessions) do
		if opts.bead_id and session.bead_id == opts.bead_id then
			M.open(session.uuid)
			return
		elseif opts.rig and session.rig == opts.rig then
			M.open(session.uuid)
			return
		end
	end

	vim.notify("bvnvim: no matching session found", vim.log.levels.WARN)
end

return M
