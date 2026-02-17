---@mod telescope._extensions.bvnvim Telescope extension for bvnvim
---@brief [[
---Three Telescope pickers for the bvnvim plugin:
---
---  :Telescope bvnvim beads     — browse beads with fuzzy search
---  :Telescope bvnvim formulas  — browse formula definitions
---  :Telescope bvnvim sessions  — browse session transcripts
---
---Also accessible via :Beads command subcommands.
---
---Register in Neovim config:
---  require("telescope").load_extension("bvnvim")
---
---Dependencies: nvim-telescope/telescope.nvim
---@brief ]]

local has_telescope, telescope = pcall(require, "telescope")
if not has_telescope then
	return
end

local pickers  = require("telescope.pickers")
local finders  = require("telescope.finders")
local conf     = require("telescope.config").values
local actions  = require("telescope.actions")
local action_state = require("telescope.actions.state")
local previewers   = require("telescope.previewers")

local beads_data   = require("bvnvim.data.beads")
local formulas_data = require("bvnvim.data.formulas")
local sessions_data = require("bvnvim.data.sessions")
local highlight    = require("bvnvim.highlight")

-- ============================================================================
-- Helpers
-- ============================================================================

---Priority label with color code for display
---@param priority number|string
---@return string label
local function priority_label(priority)
	local p = tonumber(tostring(priority or "4"):match("%d")) or 4
	return string.format("P%d", p)
end

---Status short label
---@param status string
---@return string
local function status_label(status)
	local map = {
		open        = "○",
		in_progress = "◐",
		closed      = "✓",
	}
	return map[(status or "open"):lower()] or "○"
end

---Format a file size in human-readable form
---@param bytes number
---@return string
local function human_size(bytes)
	if bytes < 1024 then return bytes .. "B" end
	if bytes < 1048576 then return string.format("%.0fK", bytes / 1024) end
	return string.format("%.1fM", bytes / 1048576)
end

---Format ISO timestamp as short date/time
---@param ts string|nil ISO timestamp
---@return string
local function short_ts(ts)
	if not ts then return "" end
	return ts:sub(1, 10) .. " " .. (ts:match("T(%d%d:%d%d)") or "")
end

-- ============================================================================
-- Beads picker
-- ============================================================================

---Beads picker: fuzzy search over beads with priority/status highlights.
---CR: open bead detail buffer.
---@param opts? table Options: status, rig, limit
local function pick_beads(opts)
	opts = opts or {}

	local ok, bvnvim = pcall(require, "bvnvim")
	local current_rig = ok and bvnvim.state and bvnvim.state.current_rig or nil

	local bead_list, err = beads_data.list({
		status = opts.status,
		rig    = opts.rig or current_rig,
		limit  = opts.limit or 200,
	})
	if err then
		vim.notify("bvnvim: error loading beads: " .. err, vim.log.levels.ERROR)
		return
	end

	-- Build display strings
	local entries = {}
	for _, bead in ipairs(bead_list or {}) do
		local display = string.format(
			"%-14s  %s  %s  %-8s  %s",
			bead.id or "",
			status_label(bead.status),
			priority_label(bead.priority),
			(bead.type or "task"):sub(1, 8),
			bead.title or ""
		)
		table.insert(entries, { display = display, bead = bead })
	end

	pickers.new(opts, {
		prompt_title = "Beads",
		finder = finders.new_table({
			results = entries,
			entry_maker = function(entry)
				return {
					value   = entry.bead,
					display = entry.display,
					ordinal = (entry.bead.id or "") .. " " .. (entry.bead.title or ""),
				}
			end,
		}),
		sorter = conf.generic_sorter(opts),
		previewer = previewers.new_buffer_previewer({
			title = "Bead Detail",
			define_preview = function(self, entry)
				local bead = entry.value
				local lines = {
					"# " .. (bead.title or ""),
					"",
					"Status:    " .. (bead.status or "") .. "  Priority: P" .. (bead.priority or "2"),
					"Type:      " .. (bead.type or ""),
					"Assignee:  " .. (bead.owner or bead.assignee or ""),
					"",
					string.rep("─", 40),
					"",
				}
				-- Description
				local desc = bead.description or ""
				for _, l in ipairs(vim.split(desc, "\n", { plain = true })) do
					table.insert(lines, l)
				end
				vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
			end,
		}),
		attach_mappings = function(prompt_bufnr)
			actions.select_default:replace(function()
				local selection = action_state.get_selected_entry()
				actions.close(prompt_bufnr)
				if selection then
					local detail_buf = require("bvnvim.buffer.beads_detail")
					detail_buf.open(selection.value.id)
				end
			end)
			return true
		end,
	}):find()
end

-- ============================================================================
-- Formulas picker
-- ============================================================================

---Formulas picker: browse formula definitions.
---CR: open formula TOML in a read-only buffer.
---@param opts? table
local function pick_formulas(opts)
	opts = opts or {}

	local formula_list, err = formulas_data.list()
	if err then
		vim.notify("bvnvim: error loading formulas: " .. err, vim.log.levels.ERROR)
		return
	end

	local entries = {}
	for _, f in ipairs(formula_list or {}) do
		local display = string.format(
			"%-40s  %-8s  %s",
			f.name or "",
			f.version or "",
			(f.description or ""):sub(1, 50)
		)
		table.insert(entries, { display = display, formula = f })
	end

	pickers.new(opts, {
		prompt_title = "Formulas",
		finder = finders.new_table({
			results = entries,
			entry_maker = function(entry)
				return {
					value   = entry.formula,
					display = entry.display,
					ordinal = entry.formula.name or "",
				}
			end,
		}),
		sorter = conf.generic_sorter(opts),
		previewer = previewers.new_buffer_previewer({
			title = "Formula TOML",
			define_preview = function(self, entry)
				local name = entry.value.name
				local toml, toml_err = formulas_data.read(name)
				if toml_err then
					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false,
						{ "Error: " .. toml_err })
					return
				end
				local lines = vim.split(toml or "", "\n", { plain = true })
				vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
				vim.api.nvim_set_option_value("filetype", "toml",
					{ buf = self.state.bufnr })
			end,
		}),
		attach_mappings = function(prompt_bufnr)
			actions.select_default:replace(function()
				local selection = action_state.get_selected_entry()
				actions.close(prompt_bufnr)
				if selection then
					-- Open TOML in a scratch buffer
					local name = selection.value.name
					local toml, toml_err = formulas_data.read(name)
					if toml_err then
						vim.notify("bvnvim: " .. toml_err, vim.log.levels.ERROR)
						return
					end
					local bufnr = vim.api.nvim_create_buf(false, true)
					vim.api.nvim_buf_set_name(bufnr, "formula://" .. name)
					vim.api.nvim_buf_set_lines(bufnr, 0, -1, false,
						vim.split(toml or "", "\n", { plain = true }))
					vim.api.nvim_set_option_value("buftype", "nofile", { buf = bufnr })
					vim.api.nvim_set_option_value("filetype", "toml",  { buf = bufnr })
					vim.api.nvim_set_option_value("modifiable", false,  { buf = bufnr })
					vim.api.nvim_set_current_buf(bufnr)
				end
			end)
			return true
		end,
	}):find()
end

-- ============================================================================
-- Sessions picker
-- ============================================================================

---Sessions picker: browse recent Claude Code session transcripts.
---CR: open session transcript buffer.
---@param opts? table Options: project_path
local function pick_sessions(opts)
	opts = opts or {}

	local session_list, err = sessions_data.list_sessions(opts.project_path)
	if err then
		vim.notify("bvnvim: error loading sessions: " .. err, vim.log.levels.ERROR)
		return
	end

	local entries = {}
	for _, s in ipairs(session_list or {}) do
		local date = short_ts(s.last_ts or s.first_ts)
		local rig  = s.rig or s.project or ""
		local display = string.format(
			"%-20s  %-20s  %3d turns  %s",
			date,
			rig:sub(1, 20),
			s.n_turns or 0,
			human_size(s.size or 0)
		)
		table.insert(entries, { display = display, session = s })
	end

	pickers.new(opts, {
		prompt_title = "Sessions",
		finder = finders.new_table({
			results = entries,
			entry_maker = function(entry)
				return {
					value   = entry.session,
					display = entry.display,
					ordinal = (entry.session.uuid or "") .. " "
						.. (entry.session.cwd or ""),
				}
			end,
		}),
		sorter = conf.generic_sorter(opts),
		previewer = previewers.new_buffer_previewer({
			title = "Session Transcript",
			define_preview = function(self, entry)
				local session = entry.value
				local transcript, t_err = sessions_data.extract_transcript(session.path)
				if t_err then
					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false,
						{ "Error: " .. t_err })
					return
				end
				-- Show first 100 lines of transcript in preview
				local lines = vim.split(transcript or "", "\n", { plain = true })
				local preview_lines = vim.list_slice(lines, 1, 100)
				vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, preview_lines)
			end,
		}),
		attach_mappings = function(prompt_bufnr)
			actions.select_default:replace(function()
				local selection = action_state.get_selected_entry()
				actions.close(prompt_bufnr)
				if selection then
					local session_buf = require("bvnvim.buffer.session")
					session_buf.open(selection.value.uuid)
				end
			end)
			return true
		end,
	}):find()
end

-- ============================================================================
-- Extension registration
-- ============================================================================

return telescope.register_extension({
	exports = {
		-- :Telescope bvnvim beads
		beads = function(opts)
			pick_beads(opts)
		end,
		-- :Telescope bvnvim formulas
		formulas = function(opts)
			pick_formulas(opts)
		end,
		-- :Telescope bvnvim sessions
		sessions = function(opts)
			pick_sessions(opts)
		end,
		-- default: beads picker
		bvnvim = function(opts)
			pick_beads(opts)
		end,
	},
})
