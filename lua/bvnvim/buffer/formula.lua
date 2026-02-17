---@mod bvnvim.buffer.formula Formula definition + execution history buffer
---@brief [[
---Two buffer modes for formula content:
---
---1. Definition: formula://<name>
---   Loads raw_toml from Dolt (or filesystem fallback).
---   buftype=acwrite so :w triggers BufWriteCmd → formulas_data.save().
---   extmark decorations overlay step dependency graph as virtual text.
---   filetype=toml for syntax highlighting.
---
---2. Execution history: formula-runs://<name>
---   Lists recent runs with status + per-step bead mapping.
---   Read-only, buftype=nofile.
---
---Keymaps (definition buffer):
---  q        close
---  r        reload from Dolt
---  <C-s>    save (same as :w)
---  gd       diff current content against Dolt (if available)
---
---Keymaps (runs buffer):
---  q        close
---  r        reload run list
---  <CR>     show run detail in a split
---@brief ]]

local formulas_data = require("bvnvim.data.formulas")
local highlight     = require("bvnvim.highlight")

local M = {}

-- ============================================================================
-- Definition buffer
-- ============================================================================

---Get or create a buffer for a formula definition
---@param name string Formula name
---@return number bufnr
local function get_def_buf(name)
	local uri      = "formula://" .. name
	local existing = vim.fn.bufnr(uri)
	if existing ~= -1 then
		return existing
	end
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(bufnr, uri)
	return bufnr
end

---Add virtual text annotations for formula steps (dependency graph overlay).
---Reads structured data from Dolt if available; no-ops if unavailable.
---@param bufnr number
---@param name string Formula name
local function annotate_steps(bufnr, name)
	local structured, err = formulas_data.read_structured(name)
	if err or not structured or not structured.steps then
		return
	end
	local ns_id = highlight.get_namespace()

	-- Find step positions in the TOML by scanning for [[steps]] sections
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local step_idx = 1
	for row, line in ipairs(lines) do
		-- Match [[steps]] section header
		if line:match("%[%[steps%]%]") then
			local step = structured.steps[step_idx]
			if step then
				local deps_str = #step.depends_on > 0
					and (" ← " .. table.concat(step.depends_on, ", "))
					or " (root)"
				vim.api.nvim_buf_set_extmark(bufnr, ns_id, row - 1, 0, {
					virt_text     = { { deps_str, "BvnvimLabel" } },
					virt_text_pos = "eol",
				})
				step_idx = step_idx + 1
			end
		end
	end
end

---Set up keymaps and BufWriteCmd for the definition buffer.
---@param bufnr number
---@param name string Formula name
local function setup_def_buffer(bufnr, name)
	local km_opts = { buffer = bufnr, silent = true, noremap = true }

	-- BufWriteCmd: validate and save to Dolt
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		buffer   = bufnr,
		callback = function()
			local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
			local toml  = table.concat(lines, "\n")
			local ok, err = formulas_data.save(name, toml)
			if err then
				vim.notify("bvnvim: formula save failed: " .. err, vim.log.levels.ERROR)
			else
				vim.notify("bvnvim: saved formula " .. name, vim.log.levels.INFO)
				vim.api.nvim_set_option_value("modified", false, { buf = bufnr })
			end
		end,
	})

	-- q: close
	vim.keymap.set("n", "q", function()
		vim.api.nvim_buf_delete(bufnr, { force = true })
	end, km_opts)

	-- r: reload
	vim.keymap.set("n", "r", function()
		M.open(name)
	end, km_opts)

	-- <C-s>: save
	vim.keymap.set({ "n", "i" }, "<C-s>", function()
		vim.cmd("write")
	end, km_opts)
end

---Open a formula definition buffer.
---@param name string Formula name (e.g. "shiny", "spec-workflow")
function M.open(name)
	if not name or name == "" then
		vim.notify("bvnvim: formula name required", vim.log.levels.ERROR)
		return
	end

	local toml, err = formulas_data.read(name)
	if err then
		vim.notify("bvnvim: error loading formula " .. name .. ": " .. err, vim.log.levels.ERROR)
		return
	end

	local bufnr = get_def_buf(name)

	-- Buffer options
	vim.api.nvim_set_option_value("buftype",    "acwrite", { buf = bufnr })
	vim.api.nvim_set_option_value("bufhidden",  "wipe",    { buf = bufnr })
	vim.api.nvim_set_option_value("swapfile",   false,     { buf = bufnr })
	vim.api.nvim_set_option_value("filetype",   "toml",    { buf = bufnr })
	vim.api.nvim_set_option_value("modifiable", true,      { buf = bufnr })

	-- Write content
	local lines = vim.split(toml or "", "\n", { plain = true })
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modified", false, { buf = bufnr })

	-- Open in current window
	vim.api.nvim_set_current_buf(bufnr)

	-- Annotations + keymaps
	annotate_steps(bufnr, name)
	setup_def_buffer(bufnr, name)
end

-- ============================================================================
-- Execution history buffer
-- ============================================================================

---Open a formula runs (execution history) buffer.
---@param name string Formula name
function M.open_runs(name)
	if not name or name == "" then
		vim.notify("bvnvim: formula name required", vim.log.levels.ERROR)
		return
	end

	local runs, err = formulas_data.runs(name, 20)
	if err then
		vim.notify("bvnvim: error loading runs for " .. name .. ": " .. err, vim.log.levels.ERROR)
		return
	end

	local uri      = "formula-runs://" .. name
	local existing = vim.fn.bufnr(uri)
	if existing ~= -1 then
		vim.api.nvim_buf_delete(existing, { force = true })
	end
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(bufnr, uri)

	-- Build lines
	local lines = { "# Runs: " .. name, "" }
	local run_ids = {}
	for _, run in ipairs(runs or {}) do
		local status_sym = run.status == "completed" and "✓"
			or run.status == "running" and "◐"
			or "○"
		local line = string.format(
			"%s  %-12s  %-20s  %s",
			status_sym,
			run.id or "",
			(run.started_at or ""):sub(1, 19),
			run.status or ""
		)
		table.insert(lines, line)
		table.insert(run_ids, run.id)
	end
	if #runs == 0 then
		table.insert(lines, "(no runs found)")
	end

	-- Buffer settings
	vim.api.nvim_set_option_value("buftype",    "nofile",         { buf = bufnr })
	vim.api.nvim_set_option_value("bufhidden",  "wipe",           { buf = bufnr })
	vim.api.nvim_set_option_value("swapfile",   false,            { buf = bufnr })
	vim.api.nvim_set_option_value("modifiable", true,             { buf = bufnr })
	vim.api.nvim_set_option_value("filetype",   "bvnvim-formula", { buf = bufnr })

	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

	vim.api.nvim_set_current_buf(bufnr)

	local km_opts = { buffer = bufnr, silent = true, noremap = true }

	-- q: close
	vim.keymap.set("n", "q", function()
		vim.api.nvim_buf_delete(bufnr, { force = true })
	end, km_opts)

	-- r: reload
	vim.keymap.set("n", "r", function()
		M.open_runs(name)
	end, km_opts)

	-- <CR>: show run detail
	vim.keymap.set("n", "<CR>", function()
		local row = vim.api.nvim_win_get_cursor(0)[1] - 1
		-- Data rows start at index 2 (0-indexed), header is 0, blank is 1
		local run_idx = row - 1
		local run_id  = run_ids[run_idx]
		if not run_id then return end

		local detail, d_err = formulas_data.run_detail(run_id)
		if d_err then
			vim.notify("bvnvim: " .. d_err, vim.log.levels.ERROR)
			return
		end

		-- Show in a split
		vim.cmd("split")
		local dbufnr = vim.api.nvim_create_buf(false, true)
		local dlines = { "# Run: " .. run_id, "" }
		for _, item in ipairs(detail or {}) do
			table.insert(dlines, string.format("  %s  %s  %s",
				item.step_id or "", item.status or "", (item.started_at or ""):sub(1, 16)))
			if item.output and item.output ~= "" then
				table.insert(dlines, "  " .. item.output:sub(1, 80))
			end
		end
		vim.api.nvim_buf_set_lines(dbufnr, 0, -1, false, dlines)
		vim.api.nvim_set_option_value("buftype",    "nofile", { buf = dbufnr })
		vim.api.nvim_set_option_value("modifiable", false,    { buf = dbufnr })
		vim.api.nvim_set_current_buf(dbufnr)
	end, km_opts)

	-- Highlight header
	highlight.highlight_range(bufnr, 0, 0, 0, #lines[1], "BvnvimHeader")
end

return M
