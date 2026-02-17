---@mod bvnvim.buffer.beads_list Beads list buffer
---@brief [[
---Renders a fixed-column table of beads in a scratch buffer.
---
---Layout:
---  ID            TYPE      TITLE
---  ─────────────────────────────────────────
---  bv-lj7        task      Buffer rendering — beads list…
---
---Virtual text extmarks overlay priority badges and status indicators.
---Line-to-bead mapping stored in vim.b[bufnr].bvnvim_line_map:
---  table of {row=number, id=string} pairs
---
---Keymaps:
---  <CR>  open detail view for bead under cursor
---  r     refresh list
---  q     close buffer
---@brief ]]

local beads_data = require("bvnvim.data.beads")
local highlight = require("bvnvim.highlight")

local M = {}

local BUFNAME = "bvnvim://beads-list"

-- Column widths (characters)
local COL_ID    = 14
local COL_TYPE  = 10

-- Type abbreviations for display
local TYPE_ABBR = {
	task             = "task",
	bug              = "bug",
	feature          = "feat",
	epic             = "epic",
	decision         = "adr",
	["merge-request"] = "mr",
}

---Get or create the singleton beads list buffer
---@return number bufnr
local function get_or_create_buf()
	local existing = vim.fn.bufnr(BUFNAME)
	if existing ~= -1 then
		return existing
	end
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(bufnr, BUFNAME)
	return bufnr
end

---Truncate a string to max length, appending "…" if truncated
---@param s string
---@param max number
---@return string
local function truncate(s, max)
	s = s or ""
	if #s <= max then
		return s
	end
	return s:sub(1, max - 1) .. "…"
end

---Pad or truncate string to exact width
---@param s string
---@param width number
---@return string
local function pad(s, width)
	s = s or ""
	if #s >= width then
		return s:sub(1, width)
	end
	return s .. string.rep(" ", width - #s)
end

---Render bead list into buffer lines and apply extmarks
---@param bufnr number
---@param bead_list table[] List of bead objects from beads_data.list()
local function render(bufnr, bead_list)
	local ns_id = highlight.get_namespace()
	highlight.clear_extmarks(bufnr)

	local lines   = {}
	local line_map = {} -- {row=number, id=string}

	-- Header
	local header = pad("ID", COL_ID) .. pad("TYPE", COL_TYPE) .. "TITLE"
	table.insert(lines, header)
	table.insert(lines, string.rep("─", math.min(#header + 20, 80)))

	-- Bead rows (header occupies rows 0 and 1)
	for _, bead in ipairs(bead_list) do
		local id    = pad(bead.id or "", COL_ID)
		local btype = pad(TYPE_ABBR[bead.type] or (bead.type or ""), COL_TYPE)
		local title = truncate(bead.title or "", 60)
		table.insert(lines, id .. btype .. title)
		-- 0-indexed row
		local row = #lines - 1
		table.insert(line_map, { row = row, id = bead.id })
	end

	-- Write lines
	vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

	-- Store line map for keymap handlers
	vim.b[bufnr].bvnvim_line_map = line_map

	-- Highlight header
	highlight.highlight_range(bufnr, 0, 0, 0, #header, "BvnvimHeader")

	-- Add priority badge + status indicator per bead row
	for _, entry in ipairs(line_map) do
		-- Find the matching bead object
		local bead = nil
		for _, b in ipairs(bead_list) do
			if b.id == entry.id then
				bead = b
				break
			end
		end
		if bead then
			-- Priority badge overlaid on the ID column
			local prio_str = tostring(bead.priority or "4")
			local prio_num = tonumber(prio_str:match("%d"))
			if prio_num then
				highlight.add_priority_badge(bufnr, entry.row, 0, prio_num)
			end
			-- Status indicator after ID column
			local status = (bead.status or "open"):lower()
			highlight.add_status_indicator(bufnr, entry.row, COL_ID, status)
		end
	end
end

---Set up keymaps for the beads list buffer
---@param bufnr number
---@param opts? table Filter options to pass on refresh
local function setup_keymaps(bufnr, opts)
	local km_opts = { buffer = bufnr, silent = true, noremap = true }

	-- <CR>: open detail view
	vim.keymap.set("n", "<CR>", function()
		local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1 -- 0-indexed
		local line_map   = vim.b[bufnr].bvnvim_line_map or {}
		for _, entry in ipairs(line_map) do
			if entry.row == cursor_row then
				local detail = require("bvnvim.buffer.beads_detail")
				detail.open(entry.id)
				return
			end
		end
		vim.notify("bvnvim: no bead on this line", vim.log.levels.WARN)
	end, km_opts)

	-- r: refresh
	vim.keymap.set("n", "r", function()
		M.refresh(bufnr, opts)
	end, km_opts)

	-- q: close
	vim.keymap.set("n", "q", function()
		vim.api.nvim_buf_delete(bufnr, { force = true })
	end, km_opts)
end

---Reload bead data and re-render the list buffer
---@param bufnr number
---@param opts? table Filter options: status, rig, limit, priority
function M.refresh(bufnr, opts)
	opts = opts or {}
	local bead_list, err = beads_data.list({
		status   = opts.status,
		rig      = opts.rig,
		limit    = opts.limit or 50,
		priority = opts.priority,
	})
	if err then
		vim.notify("bvnvim: error loading beads: " .. err, vim.log.levels.ERROR)
		return
	end
	render(bufnr, bead_list or {})
end

---Open the beads list in the current window
---@param opts? table Filter options: status, rig, limit, priority
function M.open(opts)
	opts = opts or {}
	local bufnr = get_or_create_buf()

	-- Buffer settings
	vim.api.nvim_set_option_value("buftype",    "nofile", { buf = bufnr })
	vim.api.nvim_set_option_value("bufhidden",  "wipe",   { buf = bufnr })
	vim.api.nvim_set_option_value("swapfile",   false,    { buf = bufnr })
	vim.api.nvim_set_option_value("modifiable", false,    { buf = bufnr })
	vim.api.nvim_set_option_value("filetype", "bvnvim-beads", { buf = bufnr })

	vim.api.nvim_set_current_buf(bufnr)
	setup_keymaps(bufnr, opts)
	M.refresh(bufnr, opts)
end

return M
