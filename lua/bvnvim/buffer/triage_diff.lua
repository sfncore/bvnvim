---@mod bvnvim.buffer.triage_diff Triage diff view buffer
---@brief [[
---Displays bv triage proposals as an interactive diff with accept/reject toggles.
---
---Buffer URI: triage://<rig>
---buftype:     nofile (read-only, uses keymaps for interaction)
---
---Format:
---  # Triage: <rig>
---
---  [✓] bv-lj7  status    open         → in_progress   (score: 0.85)
---  [ ] bv-smm  priority  2            → 1             (score: 0.72)
---  ...
---
---Keymaps:
---  <Space>  toggle accept/reject for proposal under cursor
---  <CR>     open bead detail for proposal under cursor
---  M        merge all accepted proposals (calls bd update for each)
---  r        reload proposals from bv
---  q        close buffer
---
---Data source: bv --robot-triage --format json --dolt --rig <rig>
---@brief ]]

local analysis_data = require("bvnvim.data.analysis")
local beads_data    = require("bvnvim.data.beads")
local highlight     = require("bvnvim.highlight")

local M = {}

-- Per-buffer state: {rig, proposals, accepted}
local _state = {}

---Get or create a triage buffer for a rig
---@param rig string
---@return number bufnr
local function get_buf(rig)
	local uri      = "triage://" .. rig
	local existing = vim.fn.bufnr(uri)
	if existing ~= -1 then
		vim.api.nvim_buf_delete(existing, { force = true })
	end
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(bufnr, uri)
	return bufnr
end

---Render proposals into buffer lines.
---@param bufnr number
---@param rig string
---@param proposals table[] Proposal objects from bv triage output
---@param accepted table<number,boolean> Map of row → accepted
local function render(bufnr, rig, proposals, accepted)
	local ns_id = highlight.get_namespace()
	highlight.clear_extmarks(bufnr)

	local lines = { "# Triage: " .. rig, "" }
	local line_map = {} -- {row=0indexed, proposal_idx}

	for i, prop in ipairs(proposals) do
		local check  = accepted[i] and "[✓]" or "[ ]"
		local bead_id = prop.bead_id or prop.id or ""
		local field   = prop.field or ""
		local old_val = tostring(prop.old_value or "")
		local new_val = tostring(prop.new_value or "")
		local score   = prop.score and string.format("(score: %.2f)", prop.score) or ""

		local line = string.format(
			"%s  %-12s  %-12s  %-16s → %-16s  %s",
			check, bead_id, field, old_val:sub(1, 16), new_val:sub(1, 16), score
		)
		table.insert(lines, line)
		table.insert(line_map, { row = #lines - 1, idx = i })
	end

	if #proposals == 0 then
		table.insert(lines, "(no proposals — triage is clean)")
	end

	vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

	-- Store line map in buffer state
	_state[bufnr].line_map = line_map

	-- Highlights
	highlight.highlight_range(bufnr, 0, 0, 0, #lines[1], "BvnvimHeader")
	for _, entry in ipairs(line_map) do
		local prop = proposals[entry.idx]
		if prop then
			-- Accepted rows: BvnvimOpen color; rejected: BvnvimDim
			local hl = accepted[entry.idx] and "BvnvimOpen" or "BvnvimDim"
			highlight.highlight_range(bufnr, entry.row, 0, entry.row, 5, hl)
		end
	end
end

---Find the proposal index at the current cursor row.
---@param bufnr number
---@return number|nil idx
local function proposal_at_cursor(bufnr)
	local row      = vim.api.nvim_win_get_cursor(0)[1] - 1
	local state    = _state[bufnr] or {}
	for _, entry in ipairs(state.line_map or {}) do
		if entry.row == row then
			return entry.idx
		end
	end
	return nil
end

---Set up keymaps for the triage buffer.
---@param bufnr number
---@param rig string
local function setup_keymaps(bufnr, rig)
	local km_opts = { buffer = bufnr, silent = true, noremap = true }
	local state   = _state[bufnr]

	-- <Space>: toggle accept/reject
	vim.keymap.set("n", "<Space>", function()
		local idx = proposal_at_cursor(bufnr)
		if not idx then return end
		state.accepted[idx] = not state.accepted[idx]
		render(bufnr, rig, state.proposals, state.accepted)
	end, km_opts)

	-- <CR>: open bead detail
	vim.keymap.set("n", "<CR>", function()
		local idx = proposal_at_cursor(bufnr)
		if not idx then return end
		local prop    = state.proposals[idx]
		local bead_id = prop and (prop.bead_id or prop.id)
		if bead_id then
			local detail_buf = require("bvnvim.buffer.beads_detail")
			detail_buf.open(bead_id)
		end
	end, km_opts)

	-- M: merge accepted proposals
	vim.keymap.set("n", "M", function()
		local merged = 0
		local errors = {}
		for i, prop in ipairs(state.proposals) do
			if state.accepted[i] then
				local bead_id = prop.bead_id or prop.id
				local field   = prop.field
				local new_val = prop.new_value
				if bead_id and field and new_val ~= nil then
					local ok, err = beads_data.update(bead_id, { [field] = tostring(new_val) })
					if err then
						table.insert(errors, bead_id .. ": " .. err)
					else
						merged = merged + 1
					end
				end
			end
		end
		if #errors > 0 then
			vim.notify("bvnvim: merge errors:\n" .. table.concat(errors, "\n"),
				vim.log.levels.ERROR)
		end
		if merged > 0 then
			vim.notify(string.format("bvnvim: merged %d proposal(s)", merged),
				vim.log.levels.INFO)
		end
		-- Reload
		M.open(rig)
	end, km_opts)

	-- r: reload
	vim.keymap.set("n", "r", function()
		M.open(rig)
	end, km_opts)

	-- q: close
	vim.keymap.set("n", "q", function()
		_state[bufnr] = nil
		vim.api.nvim_buf_delete(bufnr, { force = true })
	end, km_opts)
end

---Open the triage diff view for a rig.
---Fetches proposals from bv --robot-triage and renders them.
---@param rig_name string Rig to triage
function M.open(rig_name)
	if not rig_name or rig_name == "" then
		vim.notify("bvnvim: triage requires a rig name", vim.log.levels.ERROR)
		return
	end

	local bufnr = get_buf(rig_name)

	-- Buffer options
	vim.api.nvim_set_option_value("buftype",    "nofile",          { buf = bufnr })
	vim.api.nvim_set_option_value("bufhidden",  "wipe",            { buf = bufnr })
	vim.api.nvim_set_option_value("swapfile",   false,             { buf = bufnr })
	vim.api.nvim_set_option_value("modifiable", false,             { buf = bufnr })
	vim.api.nvim_set_option_value("filetype",   "bvnvim-triage",   { buf = bufnr })

	-- Show loading message
	vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "# Triage: " .. rig_name, "", "Loading…" })
	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

	vim.api.nvim_set_current_buf(bufnr)

	-- Initialize state
	_state[bufnr] = { rig = rig_name, proposals = {}, accepted = {}, line_map = {} }

	-- Fetch triage data async
	analysis_data.triage({ rig = rig_name }, function(result, err)
		if err then
			vim.schedule(function()
				vim.notify("bvnvim: triage error: " .. err, vim.log.levels.ERROR)
				vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
				vim.api.nvim_buf_set_lines(bufnr, 0, -1, false,
					{ "# Triage: " .. rig_name, "", "Error: " .. err })
				vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
			end)
			return
		end

		vim.schedule(function()
			-- Parse proposals from result
			local proposals = {}
			if type(result) == "table" then
				-- Expect result to be an array of proposal objects,
				-- or {proposals = [...]} depending on bv output schema
				local raw = result.proposals or result
				if type(raw) == "table" then
					for _, p in ipairs(raw) do
						if type(p) == "table" then
							table.insert(proposals, p)
						end
					end
				end
			end

			local state   = _state[bufnr]
			if not state then return end -- buffer was closed
			state.proposals = proposals
			state.accepted  = {}
			for i = 1, #proposals do
				state.accepted[i] = false
			end

			render(bufnr, rig_name, proposals, state.accepted)
			setup_keymaps(bufnr, rig_name)
		end)
	end)
end

return M
