---@mod bvnvim.data.beads Data layer for beads (bd CLI wrapper)
---@brief [[
---Low-level data access layer wrapping the bd CLI.
---Provides synchronous and asynchronous functions for CRUD operations on beads.
---@brief ]]

local config = require("bvnvim.config")

---@class BeadsData
---@field _config BvnvimConfig Cached configuration
local M = {}

---Initialize the data module with configuration
---@param cfg? BvnvimConfig Configuration (uses defaults if not provided)
function M.setup(cfg)
	M._config = cfg or config.defaults
end

---Get the bd command with optional rig flag
---@param rig? string Rig name (uses default_rig if not provided)
---@return string base_cmd The base bd command
---@return string[] extra_args Extra arguments to prepend
local function get_bd_cmd(rig)
	local cfg = M._config or config.defaults
	local cmd = cfg.bd_cmd or "bd"
	local args = {}

	if rig then
		table.insert(args, "--rig")
		table.insert(args, rig)
	elseif cfg.default_rig then
		table.insert(args, "--rig")
		table.insert(args, cfg.default_rig)
	end

	return cmd, args
end

---Parse JSON output from bd command
---@param output string JSON string from bd CLI
---@return table|nil data Parsed data or nil on error
---@return string|nil err Error message if parsing failed
local function parse_json(output)
	if not output or output == "" then
		return nil, "Empty output from bd CLI"
	end

	-- Trim whitespace
	output = output:gsub("^%s+", ""):gsub("%s+$", "")

	local ok, result = pcall(vim.json.decode, output)
	if not ok then
		return nil, "JSON parse error: " .. tostring(result)
	end

	return result, nil
end

---Build shell command from parts
---@param base_cmd string Base command
---@param args string[] Arguments
---@return string shell_cmd Complete shell command
local function build_shell_cmd(base_cmd, args)
	local cmd_parts = { base_cmd }
	for _, arg in ipairs(args) do
		-- Simple shell escaping for arguments
		local escaped = arg:gsub("'", "'\"'\"'")
		table.insert(cmd_parts, "'" .. escaped .. "'")
	end
	return table.concat(cmd_parts, " ")
end

---List beads with optional filters
---@param opts? {rig?: string, status?: string, type?: string, assignee?: string, limit?: number}
---@return table[]|nil beads List of beads or nil on error
---@return string|nil err Error message
function M.list(opts)
	opts = opts or {}

	local base_cmd, extra_args = get_bd_cmd(opts.rig)
	local args = vim.deepcopy(extra_args)

	table.insert(args, "list")
	table.insert(args, "--json")

	if opts.status then
		table.insert(args, "--status")
		table.insert(args, opts.status)
	end

	if opts.type then
		table.insert(args, "--type")
		table.insert(args, opts.type)
	end

	if opts.assignee then
		table.insert(args, "--assignee")
		table.insert(args, opts.assignee)
	end

	if opts.limit then
		table.insert(args, "--limit")
		table.insert(args, tostring(opts.limit))
	end

	local shell_cmd = build_shell_cmd(base_cmd, args)
	local output = vim.fn.system(shell_cmd)

	if vim.v.shell_error ~= 0 then
		return nil, "bd list failed: " .. output
	end

	local data, err = parse_json(output)
	if err then
		return nil, err
	end

	-- bd list --json returns an array of beads
	if type(data) ~= "table" then
		return nil, "Unexpected response format from bd list"
	end

	return data, nil
end

---List beads asynchronously with callback
---@param opts? {rig?: string, status?: string, type?: string, assignee?: string, limit?: number}
---@param callback fun(beads: table[]|nil, err: string|nil) Callback function
---@return number job_id Job ID for vim.fn.jobstop if needed
function M.list_async(opts, callback)
	opts = opts or {}

	local base_cmd, extra_args = get_bd_cmd(opts.rig)
	local args = { base_cmd }

	for _, arg in ipairs(extra_args) do
		table.insert(args, arg)
	end

	table.insert(args, "list")
	table.insert(args, "--json")

	if opts.status then
		table.insert(args, "--status")
		table.insert(args, opts.status)
	end

	if opts.type then
		table.insert(args, "--type")
		table.insert(args, opts.type)
	end

	if opts.assignee then
		table.insert(args, "--assignee")
		table.insert(args, opts.assignee)
	end

	if opts.limit then
		table.insert(args, "--limit")
		table.insert(args, tostring(opts.limit))
	end

	local output_lines = {}

	local job_id = vim.fn.jobstart(args, {
		on_stdout = function(_, data, _)
			if data then
				for _, line in ipairs(data) do
					if line and line ~= "" then
						table.insert(output_lines, line)
					end
				end
			end
		end,
		on_stderr = function(_, data, _)
			if data and #data > 0 and data[1] ~= "" then
				-- Collect stderr for error reporting
				if not output_lines._stderr then
					output_lines._stderr = {}
				end
				for _, line in ipairs(data) do
					if line and line ~= "" then
						table.insert(output_lines._stderr, line)
					end
				end
			end
		end,
		on_exit = function(_, exit_code, _)
			if exit_code ~= 0 then
				local err_msg = "bd list failed (exit " .. exit_code .. ")"
				if output_lines._stderr then
					err_msg = err_msg .. ": " .. table.concat(output_lines._stderr, "\n")
				end
				callback(nil, err_msg)
				return
			end

			local output = table.concat(output_lines, "\n")
			local data, err = parse_json(output)
			if err then
				callback(nil, err)
				return
			end

			if type(data) ~= "table" then
				callback(nil, "Unexpected response format from bd list")
				return
			end

			callback(data, nil)
		end,
	})

	if job_id <= 0 then
		callback(nil, "Failed to start bd list job")
	end

	return job_id
end

---Show a single bead by ID
---@param id string Bead ID
---@param opts? {rig?: string}
---@return table|nil bead Bead data or nil on error
---@return string|nil err Error message
function M.show(id, opts)
	opts = opts or {}

	if not id or id == "" then
		return nil, "Bead ID is required"
	end

	local base_cmd, extra_args = get_bd_cmd(opts.rig)
	local args = vim.deepcopy(extra_args)

	table.insert(args, "show")
	table.insert(args, id)
	table.insert(args, "--json")

	local shell_cmd = build_shell_cmd(base_cmd, args)
	local output = vim.fn.system(shell_cmd)

	if vim.v.shell_error ~= 0 then
		return nil, "bd show failed: " .. output
	end

	local data, err = parse_json(output)
	if err then
		return nil, err
	end

	return data, nil
end

---Show a single bead asynchronously
---@param id string Bead ID
---@param opts? {rig?: string}
---@param callback fun(bead: table|nil, err: string|nil) Callback function
---@return number job_id Job ID
function M.show_async(id, opts, callback)
	opts = opts or {}

	if not id or id == "" then
		callback(nil, "Bead ID is required")
		return -1
	end

	local base_cmd, extra_args = get_bd_cmd(opts.rig)
	local args = { base_cmd }

	for _, arg in ipairs(extra_args) do
		table.insert(args, arg)
	end

	table.insert(args, "show")
	table.insert(args, id)
	table.insert(args, "--json")

	local output_lines = {}

	local job_id = vim.fn.jobstart(args, {
		on_stdout = function(_, data, _)
			if data then
				for _, line in ipairs(data) do
					if line and line ~= "" then
						table.insert(output_lines, line)
					end
				end
			end
		end,
		on_stderr = function(_, data, _)
			if data and #data > 0 and data[1] ~= "" then
				if not output_lines._stderr then
					output_lines._stderr = {}
				end
				for _, line in ipairs(data) do
					if line and line ~= "" then
						table.insert(output_lines._stderr, line)
					end
				end
			end
		end,
		on_exit = function(_, exit_code, _)
			if exit_code ~= 0 then
				local err_msg = "bd show failed (exit " .. exit_code .. ")"
				if output_lines._stderr then
					err_msg = err_msg .. ": " .. table.concat(output_lines._stderr, "\n")
				end
				callback(nil, err_msg)
				return
			end

			local output = table.concat(output_lines, "\n")
			local data, err = parse_json(output)
			if err then
				callback(nil, err)
				return
			end

			callback(data, nil)
		end,
	})

	if job_id <= 0 then
		callback(nil, "Failed to start bd show job")
	end

	return job_id
end

---Create a new bead
---@param fields {title: string, type?: string, description?: string, status?: string, priority?: string, assignee?: string, labels?: string[]}
---@param opts? {rig?: string}
---@return table|nil bead Created bead data or nil on error
---@return string|nil err Error message
function M.create(fields, opts)
	opts = opts or {}

	if not fields or not fields.title then
		return nil, "Title is required to create a bead"
	end

	local base_cmd, extra_args = get_bd_cmd(opts.rig)
	local args = vim.deepcopy(extra_args)

	table.insert(args, "create")
	table.insert(args, "--json")
	table.insert(args, "--title")
	table.insert(args, fields.title)

	if fields.type then
		table.insert(args, "--type")
		table.insert(args, fields.type)
	end

	if fields.description then
		table.insert(args, "--description")
		table.insert(args, fields.description)
	end

	if fields.status then
		table.insert(args, "--status")
		table.insert(args, fields.status)
	end

	if fields.priority then
		table.insert(args, "--priority")
		table.insert(args, fields.priority)
	end

	if fields.assignee then
		table.insert(args, "--assignee")
		table.insert(args, fields.assignee)
	end

	if fields.labels and #fields.labels > 0 then
		for _, label in ipairs(fields.labels) do
			table.insert(args, "--label")
			table.insert(args, label)
		end
	end

	local shell_cmd = build_shell_cmd(base_cmd, args)
	local output = vim.fn.system(shell_cmd)

	if vim.v.shell_error ~= 0 then
		return nil, "bd create failed: " .. output
	end

	local data, err = parse_json(output)
	if err then
		return nil, err
	end

	return data, nil
end

---Update an existing bead
---@param id string Bead ID to update
---@param fields {title?: string, description?: string, status?: string, priority?: string, assignee?: string, type?: string}
---@param opts? {rig?: string}
---@return table|nil bead Updated bead data or nil on error
---@return string|nil err Error message
function M.update(id, fields, opts)
	opts = opts or {}

	if not id or id == "" then
		return nil, "Bead ID is required"
	end

	if not fields or vim.tbl_isempty(fields) then
		return nil, "No fields to update"
	end

	local base_cmd, extra_args = get_bd_cmd(opts.rig)
	local args = vim.deepcopy(extra_args)

	table.insert(args, "update")
	table.insert(args, id)
	table.insert(args, "--json")

	if fields.title then
		table.insert(args, "--title")
		table.insert(args, fields.title)
	end

	if fields.description then
		table.insert(args, "--description")
		table.insert(args, fields.description)
	end

	if fields.status then
		table.insert(args, "--status")
		table.insert(args, fields.status)
	end

	if fields.priority then
		table.insert(args, "--priority")
		table.insert(args, fields.priority)
	end

	if fields.assignee then
		table.insert(args, "--assignee")
		table.insert(args, fields.assignee)
	end

	if fields.type then
		table.insert(args, "--type")
		table.insert(args, fields.type)
	end

	local shell_cmd = build_shell_cmd(base_cmd, args)
	local output = vim.fn.system(shell_cmd)

	if vim.v.shell_error ~= 0 then
		return nil, "bd update failed: " .. output
	end

	local data, err = parse_json(output)
	if err then
		return nil, err
	end

	return data, nil
end

---Close a bead
---@param id string Bead ID to close
---@param reason? string Optional reason for closing
---@param opts? {rig?: string}
---@return table|nil bead Closed bead data or nil on error
---@return string|nil err Error message
function M.close(id, reason, opts)
	opts = opts or {}

	if not id or id == "" then
		return nil, "Bead ID is required"
	end

	local base_cmd, extra_args = get_bd_cmd(opts.rig)
	local args = vim.deepcopy(extra_args)

	table.insert(args, "close")
	table.insert(args, id)
	table.insert(args, "--json")

	if reason then
		table.insert(args, "--message")
		table.insert(args, reason)
	end

	local shell_cmd = build_shell_cmd(base_cmd, args)
	local output = vim.fn.system(shell_cmd)

	if vim.v.shell_error ~= 0 then
		return nil, "bd close failed: " .. output
	end

	local data, err = parse_json(output)
	if err then
		return nil, err
	end

	return data, nil
end

---Get ready beads (convenience wrapper)
---@param opts? {rig?: string, limit?: number}
---@return table[]|nil beads List of ready beads or nil on error
---@return string|nil err Error message
function M.ready(opts)
	opts = opts or {}
	return M.list(vim.tbl_extend("force", opts, { status = "ready" }))
end

---Get beads assigned to a specific user
---@param assignee string Assignee identifier
---@param opts? {rig?: string, status?: string}
---@return table[]|nil beads List of assigned beads or nil on error
---@return string|nil err Error message
function M.assigned_to(assignee, opts)
	opts = opts or {}
	local list_opts = vim.tbl_extend("force", opts, { assignee = assignee })
	return M.list(list_opts)
end

return M
