---@mod bvnvim.highlight Highlight groups and extmark utilities
---@brief [[
---Highlight groups and extmark utilities for bvnvim
---
---Defines all highlight groups:
---  - BvnvimP0-P4: Priority colors (red/critical through gray/backlog)
---  - BvnvimOpen/InProgress/Completed: Status colors
---  - BvnvimHuman/Agent/Tool: Session transcript actors
---  - BvnvimWizardCursor: Wizard mode trail
---
---Provides extmark utilities for virtual text decorations in formula and bead views.
---All highlight groups are automatically recreated on ColorScheme changes.
---@brief ]]

local M = {}

---Default highlight group definitions
---Keys are highlight group names, values are attribute tables
M.groups = {
	-- Priority levels (P0 = critical/red, P4 = backlog/gray)
	BvnvimP0 = { fg = "#ff6b6b", bold = true },
	BvnvimP1 = { fg = "#ff9f43", bold = true },
	BvnvimP2 = { fg = "#feca57", bold = true },
	BvnvimP3 = { fg = "#48dbfb", bold = true },
	BvnvimP4 = { fg = "#8395a7", bold = true },

	-- Status colors
	BvnvimOpen = { fg = "#10ac84", bold = true },
	BvnvimInProgress = { fg = "#feca57", bold = true },
	BvnvimCompleted = { fg = "#8395a7", bold = true },

	-- Session transcript actors
	BvnvimHuman = { fg = "#5f27cd", bold = true },
	BvnvimAgent = { fg = "#00d2d3", bold = true },
	BvnvimTool = { fg = "#ff9ff3", bold = true },

	-- Wizard mode trail
	BvnvimWizardCursor = { fg = "#ffffff", bg = "#ff6b6b", bold = true },

	-- Additional UI elements
	BvnvimHeader = { fg = "#c8d6e5", bold = true },
	BvnvimLabel = { fg = "#8395a7" },
	BvnvimValue = { fg = "#c8d6e5" },
	BvnvimLink = { fg = "#48dbfb", underline = true },
	BvnvimCode = { fg = "#feca57", bg = "#2d3436" },
}

---Set up all highlight groups
---Called on plugin setup and ColorScheme autocmd
function M.setup()
	for name, attrs in pairs(M.groups) do
		vim.api.nvim_set_hl(0, name, attrs)
	end
end

---Create autocmd to re-apply highlights on ColorScheme change
function M._create_autocmds()
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = vim.api.nvim_create_augroup("BvnvimHighlights", { clear = true }),
		callback = function()
			M.setup()
		end,
		desc = "Re-apply bvnvim highlight groups after colorscheme change",
	})
end

---Initialize highlight module
---Called once during plugin setup
function M.init()
	M.setup()
	M._create_autocmds()
end

-- ============================================================================
-- Extmark Utilities
-- ============================================================================

---@class ExtmarkOptions
---@field virt_text? table[] Array of [text, hl_group] pairs
---@field virt_text_pos? "eol"|"overlay"|"right_align" Virtual text position
---@field virt_lines? table[] Virtual lines below the mark
---@field hl_group? string Highlight group for the extmark
---@field hl_eol? boolean Highlight to end of line
---@field priority? number Priority (higher = shown on top)
---@field ns_id? number Namespace ID (uses default if not provided)

M.ns_id = nil

---Get or create the bvnvim namespace for extmarks
---@return number Namespace ID
function M.get_namespace()
	if not M.ns_id then
		M.ns_id = vim.api.nvim_create_namespace("bvnvim")
	end
	return M.ns_id
end

---Clear all extmarks in the bvnvim namespace for a buffer
---@param bufnr? number Buffer number (defaults to current buffer)
function M.clear_extmarks(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_clear_namespace(bufnr, M.get_namespace(), 0, -1)
end

---Set an extmark with the given options
---@param bufnr number Buffer number
---@param row number 0-indexed row
---@param col number 0-indexed column
---@param opts ExtmarkOptions Extmark options
---@return number extmark_id The created extmark ID
function M.set_extmark(bufnr, row, col, opts)
	opts = opts or {}
	opts.ns_id = opts.ns_id or M.get_namespace()
	return vim.api.nvim_buf_set_extmark(bufnr, opts.ns_id, row, col, opts)
end

---Add virtual text at a specific position
---@param bufnr number Buffer number
---@param row number 0-indexed row
---@param col number 0-indexed column
---@param chunks table[] Array of [text, hl_group] pairs
---@param opts? table Additional options (priority, etc.)
---@return number extmark_id The created extmark ID
function M.add_virtual_text(bufnr, row, col, chunks, opts)
	opts = opts or {}
	local extmark_opts = {
		virt_text = chunks,
		virt_text_pos = opts.virt_text_pos or "overlay",
		priority = opts.priority or 100,
	}
	return M.set_extmark(bufnr, row, col, extmark_opts)
end

---Highlight a range of text
---@param bufnr number Buffer number
---@param start_row number Start row (0-indexed)
---@param start_col number Start column (0-indexed)
---@param end_row number End row (0-indexed)
---@param end_col number End column (0-indexed)
---@param hl_group string Highlight group name
---@param opts? table Additional options
---@return number extmark_id The created extmark ID
function M.highlight_range(bufnr, start_row, start_col, end_row, end_col, hl_group, opts)
	opts = opts or {}
	local extmark_opts = {
		end_row = end_row,
		end_col = end_col,
		hl_group = hl_group,
		priority = opts.priority or 100,
	}
	return M.set_extmark(bufnr, start_row, start_col, extmark_opts)
end

---Add a priority badge as virtual text
---@param bufnr number Buffer number
---@param row number Row to place badge
---@param col number Column to place badge
---@param priority number Priority level (0-4)
---@return number|nil extmark_id The created extmark ID or nil if invalid priority
function M.add_priority_badge(bufnr, row, col, priority)
	local hl_map = {
		[0] = "BvnvimP0",
		[1] = "BvnvimP1",
		[2] = "BvnvimP2",
		[3] = "BvnvimP3",
		[4] = "BvnvimP4",
	}

	local hl_group = hl_map[priority]
	if not hl_group then
		return nil
	end

	local text = string.format(" P%d ", priority)
	return M.add_virtual_text(bufnr, row, col, { { text, hl_group } }, { virt_text_pos = "inline" })
end

---Add a status indicator as virtual text
---@param bufnr number Buffer number
---@param row number Row to place indicator
---@param col number Column to place indicator
---@param status "open"|"in_progress"|"completed"|string Status value
---@return number|nil extmark_id The created extmark ID or nil if invalid status
function M.add_status_indicator(bufnr, row, col, status)
	local status_map = {
		open = { text = " ● ", hl = "BvnvimOpen" },
		in_progress = { text = " ◐ ", hl = "BvnvimInProgress" },
		completed = { text = " ✓ ", hl = "BvnvimCompleted" },
	}

	local mapped = status_map[status:lower()]
	if not mapped then
		return nil
	end

	return M.add_virtual_text(bufnr, row, col, { { mapped.text, mapped.hl } }, { virt_text_pos = "inline" })
end

---Add an actor indicator for session transcripts
---@param bufnr number Buffer number
---@param row number Row to place indicator
---@param col number Column to place indicator
---@param actor "human"|"agent"|"tool"|string Actor type
---@return number|nil extmark_id The created extmark ID or nil if invalid actor
function M.add_actor_indicator(bufnr, row, col, actor)
	local actor_map = {
		human = { text = " H ", hl = "BvnvimHuman" },
		agent = { text = " A ", hl = "BvnvimAgent" },
		tool = { text = " T ", hl = "BvnvimTool" },
	}

	local mapped = actor_map[actor:lower()]
	if not mapped then
		return nil
	end

	return M.add_virtual_text(bufnr, row, col, { { mapped.text, mapped.hl } }, { virt_text_pos = "inline" })
end

---Add wizard mode cursor trail
---@param bufnr number Buffer number
---@param row number Row position
---@param col number Column position
---@param opts? table Additional options
---@return number extmark_id The created extmark ID
function M.add_wizard_cursor(bufnr, row, col, opts)
	opts = opts or {}
	local char = opts.char or "█"
	return M.add_virtual_text(bufnr, row, col, { { char, "BvnvimWizardCursor" } }, { virt_text_pos = "overlay" })
end

---Clear wizard mode cursor trail from buffer
---@param bufnr? number Buffer number (defaults to current buffer)
function M.clear_wizard_cursor(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	-- Get all extmarks and filter for wizard cursor
	local ns_id = M.get_namespace()
	local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, { details = true })

	for _, mark in ipairs(extmarks) do
		local id, _, _, details = mark[1], mark[2], mark[3], mark[4]
		if details and details.virt_text then
			for _, chunk in ipairs(details.virt_text) do
				if chunk[2] == "BvnvimWizardCursor" then
					vim.api.nvim_buf_del_extmark(bufnr, ns_id, id)
					break
				end
			end
		end
	end
end

return M
