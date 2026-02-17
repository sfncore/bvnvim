---@mod bvnvim.data.analysis Analysis data layer — bv CLI wrapper
---@brief [[
---Wraps the bv CLI's --robot-* modes for cross-rig analysis.
---All functions are async by default (vim.fn.jobstart), with optional sync
---wrappers for simple one-shot use.
---
---Typical bv CLI flags:
---  bv --robot-triage  --format json [--dolt] [--workspace ~/gt/.bv/workspace.yaml]
---  bv --robot-plan    [--format json] [--rig <name>]
---  bv --robot-search  <query> [--format json]
---  bv --robot-insights [--format json]
---
---All callbacks receive (result, err) where:
---  result = parsed table (if JSON) or raw string
---  err    = string or nil
---@brief ]]

local M = {}

-- ============================================================================
-- Helpers
-- ============================================================================

---Get bv command from plugin config
---@return string
local function bv_cmd()
	local ok, bvnvim = pcall(require, "bvnvim")
	if ok and bvnvim.state and bvnvim.state.config and bvnvim.state.config.bv_cmd then
		return bvnvim.state.config.bv_cmd
	end
	return "bv"
end

---Get workspace.yaml path from config
---@return string|nil
local function workspace_yaml()
	local ok, bvnvim = pcall(require, "bvnvim")
	if ok and bvnvim.state and bvnvim.state.config then
		local gt_root = bvnvim.state.config.gt_root or vim.fn.expand("~/gt")
		local wp = gt_root .. "/.bv/workspace.yaml"
		if vim.fn.filereadable(wp) == 1 then
			return wp
		end
	end
	return nil
end

---Run a bv command asynchronously.
---Collects stdout, calls callback(result, err) on exit.
---@param args string[] Arguments to append to bv command
---@param use_json boolean If true, attempt JSON decode of output
---@param callback fun(result: table|string|nil, err: string|nil)
---@return number job_id
local function run_async(args, use_json, callback)
	local cmd_parts = { bv_cmd() }
	for _, a in ipairs(args) do
		table.insert(cmd_parts, a)
	end

	local output_lines = {}

	local job_id = vim.fn.jobstart(cmd_parts, {
		stdout_buffered = true,
		on_stdout = function(_, data, _)
			if data then
				for _, line in ipairs(data) do
					if line ~= "" then
						table.insert(output_lines, line)
					end
				end
			end
		end,
		on_exit = function(_, exit_code, _)
			local raw = table.concat(output_lines, "\n")
			if exit_code ~= 0 then
				callback(nil, "bv exited with code " .. exit_code .. ": " .. raw:sub(1, 200))
				return
			end
			if not use_json then
				callback(raw, nil)
				return
			end
			local ok, parsed = pcall(vim.json.decode, raw)
			if ok then
				callback(parsed, nil)
			else
				-- Return raw string if JSON parse fails
				callback(raw, nil)
			end
		end,
	})

	if job_id <= 0 then
		callback(nil, "bv: failed to start job (command not found?)")
	end

	return job_id
end

---Run a bv command synchronously (blocks until complete).
---@param args string[] Arguments
---@param use_json boolean
---@return table|string|nil result
---@return string|nil err
local function run_sync(args, use_json)
	local cmd_parts = { bv_cmd() }
	for _, a in ipairs(args) do
		table.insert(cmd_parts, a)
	end

	local cmd = table.concat(vim.tbl_map(vim.fn.shellescape, cmd_parts), " ") .. " 2>&1"
	local output = vim.fn.system(cmd)
	local exit_code = vim.v.shell_error

	if exit_code ~= 0 then
		return nil, "bv error (exit " .. exit_code .. "): " .. output:sub(1, 200)
	end

	if not use_json then
		return vim.trim(output), nil
	end

	local ok, parsed = pcall(vim.json.decode, output)
	if ok then
		return parsed, nil
	end
	return vim.trim(output), nil
end

---Build common workspace args
---@param opts table
---@return string[]
local function workspace_args(opts)
	local args = {}
	local wp = workspace_yaml()
	if wp and not opts.no_workspace then
		table.insert(args, "--workspace")
		table.insert(args, wp)
	end
	if opts.rig then
		table.insert(args, "--rig")
		table.insert(args, opts.rig)
	end
	return args
end

-- ============================================================================
-- Triage
-- ============================================================================

---Run bv --robot-triage asynchronously.
---Returns a structured triage report (open/stale/blocked beads across rigs).
---@param opts? table Options: rig (string), no_workspace (bool)
---@param callback fun(result: table|string|nil, err: string|nil)
---@return number job_id
function M.triage(opts, callback)
	opts = opts or {}
	local args = { "--robot-triage", "--format", "json", "--dolt" }
	for _, a in ipairs(workspace_args(opts)) do
		table.insert(args, a)
	end
	return run_async(args, true, callback)
end

---Synchronous triage (blocks).
---@param opts? table
---@return table|string|nil result
---@return string|nil err
function M.triage_sync(opts)
	opts = opts or {}
	local args = { "--robot-triage", "--format", "json", "--dolt" }
	for _, a in ipairs(workspace_args(opts)) do
		table.insert(args, a)
	end
	return run_sync(args, true)
end

-- ============================================================================
-- Plan
-- ============================================================================

---Run bv --robot-plan asynchronously.
---Returns a next-steps plan for the current rig.
---@param opts? table Options: rig (string)
---@param callback fun(result: table|string|nil, err: string|nil)
---@return number job_id
function M.plan(opts, callback)
	opts = opts or {}
	local args = { "--robot-plan", "--format", "json" }
	for _, a in ipairs(workspace_args(opts)) do
		table.insert(args, a)
	end
	return run_async(args, true, callback)
end

-- ============================================================================
-- Search
-- ============================================================================

---Run bv --robot-search asynchronously.
---@param query string Search query
---@param opts? table Options: rig (string)
---@param callback fun(result: table|string|nil, err: string|nil)
---@return number job_id
function M.search(query, opts, callback)
	opts = opts or {}
	local args = { "--robot-search", query, "--format", "json" }
	for _, a in ipairs(workspace_args(opts)) do
		table.insert(args, a)
	end
	return run_async(args, true, callback)
end

-- ============================================================================
-- Insights
-- ============================================================================

---Run bv --robot-insights asynchronously.
---Returns high-level project health metrics.
---@param opts? table Options: rig (string)
---@param callback fun(result: table|string|nil, err: string|nil)
---@return number job_id
function M.insights(opts, callback)
	opts = opts or {}
	local args = { "--robot-insights", "--format", "json" }
	for _, a in ipairs(workspace_args(opts)) do
		table.insert(args, a)
	end
	return run_async(args, true, callback)
end

return M
