---@mod bvnvim.buffer.beads_detail Bead detail buffer (bead://id URI scheme)
---@brief [[
---Renders a single bead in an editable acwrite buffer.
---
---Buffer URI:  bead://<id>   (e.g. bead://bv-lj7)
---buftype:     acwrite        (writes trigger BufWriteCmd)
---
---Format:
---  # <title>
---
---  Status:     open        Priority: P1
---  Type:       task        Assignee: mayor
---  Created:    2026-02-17  Updated:  2026-02-17
---  Tags:       label1, label2
---  ──────────────────────────────────────────────────
---
---  <description — editable markdown>
---
---On :w (BufWriteCmd): extracts title (line 1) and description (after separator)
---and calls bd update <id> --title "..." --description "..." to write back.
---
---Keymaps:
---  q     close buffer
---  r     reload from bd (discards unsaved changes)
---@brief ]]

local beads_data = require("bvnvim.data.beads")
local highlight  = require("bvnvim.highlight")

local M = {}

local SEPARATOR = string.rep("─", 50)

-- Number of header lines before the separator (used for highlight positioning)
local HEADER_ROWS = 5 -- title, blank, row1, row2, row3

---Get or create a buffer for a specific bead
---@param id string Bead ID
---@return number bufnr
local function get_or_create_buf(id)
	local name     = "bead://" .. id
	local existing = vim.fn.bufnr(name)
	if existing ~= -1 then
		return existing
	end
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(bufnr, name)
	return bufnr
end

---Format a two-column header field pair
---@param label1 string Left label
---@param value1 string Left value
---@param label2 string Right label
---@param value2 string Right value
---@param col_width number Width of the left column
---@return string
local function two_col(label1, value1, label2, value2, col_width)
	col_width = col_width or 28
	local left = label1 .. (value1 or "")
	left = left .. string.rep(" ", math.max(0, col_width - #left))
	return left .. label2 .. (value2 or "")
end

---Build buffer lines from a bead object
---@param bead table
---@return string[] lines
local function build_lines(bead)
	local lines = {}

	-- Line 0: title (editable — user can modify "# ..." to rename)
	table.insert(lines, "# " .. (bead.title or ""))
	-- Line 1: blank spacer
	table.insert(lines, "")

	-- Lines 2-4: metadata (read-only intent, not enforced)
	local status   = bead.status or "open"
	local priority = "P" .. tostring(bead.priority or "2")
	local btype    = bead.type or "task"
	local assignee = bead.owner or bead.assignee or ""
	local created  = (bead.created_at or ""):sub(1, 10)
	local updated  = (bead.updated_at or ""):sub(1, 10)

	table.insert(lines, two_col("Status:    ", status,   "Priority: ", priority))
	table.insert(lines, two_col("Type:      ", btype,    "Assignee: ", assignee))
	table.insert(lines, two_col("Created:   ", created,  "Updated:  ", updated))

	-- Optional tags line (line 5 or separator at 5)
	local tags = ""
	if bead.labels and #bead.labels > 0 then
		tags = table.concat(bead.labels, ", ")
		table.insert(lines, "Tags:      " .. tags)
	end

	-- Separator
	table.insert(lines, SEPARATOR)
	-- Blank line before body
	table.insert(lines, "")

	-- Description body
	local desc = bead.description or ""
	for line in (desc .. "\n"):gmatch("([^\n]*)\n") do
		table.insert(lines, line)
	end

	-- Remove trailing blank lines added by the split
	while #lines > 0 and lines[#lines] == "" do
		table.remove(lines)
	end
	-- Ensure at least one editable blank line at end
	table.insert(lines, "")

	return lines
end

---Apply syntax highlights to the detail buffer
---@param bufnr number
---@param bead table
---@param n_meta_lines number Number of metadata lines (varies with tags)
local function apply_highlights(bufnr, bead, n_meta_lines)
	highlight.clear_extmarks(bufnr)

	-- Title (row 0)
	highlight.highlight_range(bufnr, 0, 0, 0, -1, "BvnvimHeader")

	-- Label columns in metadata rows (rows 2 to 2+n_meta_lines-1)
	local LABEL_WIDTH = 11
	for row = 2, 2 + n_meta_lines - 1 do
		highlight.highlight_range(bufnr, row, 0, row, LABEL_WIDTH, "BvnvimLabel")
	end

	-- Status indicator inline (row 2, after label)
	local status = (bead.status or "open"):lower()
	highlight.add_status_indicator(bufnr, 2, LABEL_WIDTH, status)

	-- Priority badge inline (row 2, right side)
	local prio_num = tonumber(tostring(bead.priority or "2"):match("%d"))
	if prio_num then
		highlight.add_priority_badge(bufnr, 2, 30, prio_num)
	end
end

---Extract edited title and description from buffer content
---@param bufnr number
---@return string title
---@return string description
local function extract_content(bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	-- Title: strip leading "# "
	local title = (lines[1] or ""):gsub("^#%s*", "")

	-- Description: everything after the separator line
	local desc_lines = {}
	local past_sep   = false
	for i = 2, #lines do
		local line = lines[i]
		if not past_sep then
			if line:match("^─+$") then
				past_sep = true
			end
		else
			-- Skip first blank line after separator
			if past_sep and not desc_lines[1] and line == "" then
				-- skip this leading blank
			else
				table.insert(desc_lines, line)
			end
		end
	end

	-- Trim trailing blank lines
	while #desc_lines > 0 and desc_lines[#desc_lines] == "" do
		table.remove(desc_lines)
	end

	return title, table.concat(desc_lines, "\n")
end

---Set up autocmd and keymaps for the detail buffer
---@param bufnr number
---@param id string Bead ID
---@param bead table Bead object (for reload)
local function setup_buffer(bufnr, id, bead)
	local km_opts = { buffer = bufnr, silent = true, noremap = true }

	-- BufWriteCmd: write title + description back via bd update
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		buffer   = bufnr,
		callback = function()
			local title, desc = extract_content(bufnr)
			local ok, err = beads_data.update(id, {
				title       = title,
				description = desc,
			})
			if err then
				vim.notify("bvnvim: write failed: " .. err, vim.log.levels.ERROR)
			else
				vim.notify("bvnvim: saved " .. id, vim.log.levels.INFO)
				vim.api.nvim_set_option_value("modified", false, { buf = bufnr })
			end
		end,
	})

	-- q: close buffer
	vim.keymap.set("n", "q", function()
		vim.api.nvim_buf_delete(bufnr, { force = true })
	end, km_opts)

	-- r: reload from bd (discard edits)
	vim.keymap.set("n", "r", function()
		M.open(id)
	end, km_opts)
end

---Open a bead detail buffer in the current window
---@param id string Bead ID (e.g. "bv-lj7")
function M.open(id)
	if not id or id == "" then
		vim.notify("bvnvim: bead ID required", vim.log.levels.ERROR)
		return
	end

	local bead, err = beads_data.show(id)
	if err then
		vim.notify("bvnvim: error loading bead " .. id .. ": " .. err, vim.log.levels.ERROR)
		return
	end
	if not bead then
		vim.notify("bvnvim: bead not found: " .. id, vim.log.levels.ERROR)
		return
	end

	local bufnr = get_or_create_buf(id)

	-- Buffer settings
	vim.api.nvim_set_option_value("buftype",    "acwrite", { buf = bufnr })
	vim.api.nvim_set_option_value("bufhidden",  "wipe",    { buf = bufnr })
	vim.api.nvim_set_option_value("swapfile",   false,     { buf = bufnr })
	vim.api.nvim_set_option_value("filetype", "bvnvim-bead", { buf = bufnr })

	-- Render content
	vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
	local n_meta = 3 -- Status/Type/Created rows (without tags)
	if bead.labels and #bead.labels > 0 then
		n_meta = 4
	end
	local lines = build_lines(bead)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modified", false, { buf = bufnr })

	-- Open in current window
	vim.api.nvim_set_current_buf(bufnr)

	-- Highlights and keymaps
	apply_highlights(bufnr, bead, n_meta)
	setup_buffer(bufnr, id, bead)
end

return M
