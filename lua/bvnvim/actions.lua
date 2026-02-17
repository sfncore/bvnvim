---@mod bvnvim.actions Write-back actions via bd CLI
---@brief [[
---Provides action keymaps and helpers for modifying beads from within
---bvnvim buffers. Integrates with beads_list.lua and beads_detail.lua.
---
---List view actions (set on beads_list buffer via apply_to_list()):
---  s   set status    (vim.ui.select: open / in_progress / closed)
---  p   set priority  (vim.ui.select: P0-P4)
---  a   set assignee  (vim.ui.input)
---
---Detail view actions:
---  Inline editing + :w (BufWriteCmd) handled in beads_detail.lua.
---  After save, diff is printed to :messages for review.
---
---Triage actions:
---  M.open_triage(rig): opens triage_diff.lua for the rig.
---
---All write operations go through beads_data.update() / .close().
---@brief ]]

local beads_data = require("bvnvim.data.beads")

local M = {}

-- ============================================================================
-- Status helpers
-- ============================================================================

local STATUSES = { "open", "in_progress", "closed" }
local PRIORITIES = { "P0", "P1", "P2", "P3", "P4" }

---Get the bead ID on the current list buffer line.
---@param bufnr number
---@return string|nil id
local function bead_id_at_cursor(bufnr)
	local row      = vim.api.nvim_win_get_cursor(0)[1] - 1 -- 0-indexed
	local line_map = vim.b[bufnr].bvnvim_line_map or {}
	for _, entry in ipairs(line_map) do
		if entry.row == row then
			return entry.id
		end
	end
	return nil
end

-- ============================================================================
-- Action: set status
-- ============================================================================

---Prompt user to select a new status for the bead under cursor.
---@param bufnr number Beads list buffer number
function M.set_status(bufnr)
	local id = bead_id_at_cursor(bufnr)
	if not id then
		vim.notify("bvnvim: no bead on this line", vim.log.levels.WARN)
		return
	end

	vim.ui.select(STATUSES, {
		prompt = "Set status for " .. id .. ":",
	}, function(choice)
		if not choice then return end
		local ok, err = beads_data.update(id, { status = choice })
		if err then
			vim.notify("bvnvim: update failed: " .. err, vim.log.levels.ERROR)
		else
			vim.notify("bvnvim: " .. id .. " → " .. choice, vim.log.levels.INFO)
			-- Refresh the list buffer
			local list_buf = require("bvnvim.buffer.beads_list")
			list_buf.refresh(bufnr)
		end
	end)
end

-- ============================================================================
-- Action: set priority
-- ============================================================================

---Prompt user to select a new priority for the bead under cursor.
---@param bufnr number Beads list buffer number
function M.set_priority(bufnr)
	local id = bead_id_at_cursor(bufnr)
	if not id then
		vim.notify("bvnvim: no bead on this line", vim.log.levels.WARN)
		return
	end

	vim.ui.select(PRIORITIES, {
		prompt = "Set priority for " .. id .. ":",
	}, function(choice)
		if not choice then return end
		local pnum = choice:match("%d")
		local ok, err = beads_data.update(id, { priority = pnum })
		if err then
			vim.notify("bvnvim: update failed: " .. err, vim.log.levels.ERROR)
		else
			vim.notify("bvnvim: " .. id .. " priority → " .. choice, vim.log.levels.INFO)
			local list_buf = require("bvnvim.buffer.beads_list")
			list_buf.refresh(bufnr)
		end
	end)
end

-- ============================================================================
-- Action: set assignee
-- ============================================================================

---Prompt user to enter a new assignee for the bead under cursor.
---@param bufnr number Beads list buffer number
function M.set_assignee(bufnr)
	local id = bead_id_at_cursor(bufnr)
	if not id then
		vim.notify("bvnvim: no bead on this line", vim.log.levels.WARN)
		return
	end

	vim.ui.input({
		prompt  = "Assign " .. id .. " to: ",
	}, function(input)
		if not input or input == "" then return end
		local ok, err = beads_data.update(id, { owner = input })
		if err then
			vim.notify("bvnvim: update failed: " .. err, vim.log.levels.ERROR)
		else
			vim.notify("bvnvim: " .. id .. " assigned to " .. input, vim.log.levels.INFO)
			local list_buf = require("bvnvim.buffer.beads_list")
			list_buf.refresh(bufnr)
		end
	end)
end

-- ============================================================================
-- Apply actions to a beads list buffer
-- ============================================================================

---Install action keymaps onto a beads list buffer.
---Called from beads_list.lua after setup_keymaps().
---@param bufnr number Beads list buffer number
function M.apply_to_list(bufnr)
	local km_opts = { buffer = bufnr, silent = true, noremap = true }

	vim.keymap.set("n", "s", function()
		M.set_status(bufnr)
	end, km_opts)

	vim.keymap.set("n", "p", function()
		M.set_priority(bufnr)
	end, km_opts)

	vim.keymap.set("n", "a", function()
		M.set_assignee(bufnr)
	end, km_opts)
end

-- ============================================================================
-- Triage
-- ============================================================================

---Open the triage diff view for a rig.
---Delegates to buffer/triage_diff.lua.
---@param rig_name string
function M.open_triage(rig_name)
	local triage_buf = require("bvnvim.buffer.triage_diff")
	triage_buf.open(rig_name)
end

return M
