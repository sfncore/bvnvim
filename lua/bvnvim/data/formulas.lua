---@mod bvnvim.data.formulas Formula data layer (Dolt + filesystem fallback)
---@brief [[
---Reads formula data from the Dolt server (hq database) via the mysql CLI.
---Falls back to reading .formula.toml files from the formulas_path directory
---when Dolt is unavailable.
---
---Dolt queries use:
---  mysql -h 127.0.0.1 -P 3307 -u root hq -N -B -e '<sql>'
---
---Formula TOML files are stored in ~/gt/.beads/formulas/*.formula.toml
---
---Tables queried (hq database — formula schema may not exist yet):
---  formulas(name, raw_toml, description, version, created_at, updated_at)
---  formula_steps(formula_name, step_id, name, description, position)
---  formula_deps(formula_name, step_id, depends_on)
---  formula_vars(formula_name, name, default_value, description)
---  formula_units(formula_name, unit_name, description)
---  formula_runs(id, formula_name, status, started_at, completed_at, metadata)
---  formula_run_items(run_id, step_id, status, output, started_at, completed_at)
---@brief ]]

local M = {}

-- ============================================================================
-- Config helpers
-- ============================================================================

---Get Dolt connection config from plugin config
---@return string host, number port, boolean enabled
local function dolt_config()
	local ok, bvnvim = pcall(require, "bvnvim")
	if ok and bvnvim.state and bvnvim.state.config then
		local cfg = bvnvim.state.config
		return
			cfg.dolt_host or "127.0.0.1",
			cfg.dolt_port or 3307,
			cfg.dolt_enabled ~= false
	end
	return "127.0.0.1", 3307, true
end

---Get formulas filesystem path from config
---@return string
local function formulas_path()
	local ok, bvnvim = pcall(require, "bvnvim")
	if ok and bvnvim.state and bvnvim.state.config and bvnvim.state.config.formulas_path then
		return bvnvim.state.config.formulas_path
	end
	return vim.fn.expand("~/gt/.beads/formulas")
end

-- ============================================================================
-- Dolt / mysql helpers
-- ============================================================================

-- Cached availability flag (nil = not checked)
M._dolt_available = nil

---Check if Dolt is reachable and formula tables exist.
---Caches the result for the session.
---@return boolean available
local function dolt_available()
	if M._dolt_available ~= nil then
		return M._dolt_available
	end

	local host, port, enabled = dolt_config()
	if not enabled then
		M._dolt_available = false
		return false
	end

	-- Try a quick probe query
	local probe_cmd = string.format(
		"mysql -h %s -P %d -u root hq -N -B -e 'SELECT 1 FROM formulas LIMIT 1' 2>&1",
		host, port
	)
	local out = vim.fn.system(probe_cmd)
	M._dolt_available = (vim.v.shell_error == 0)
	return M._dolt_available
end

---Run a mysql query against the hq database.
---@param sql string SQL statement (no quoting needed for the outer shell)
---@return string|nil output, string|nil err
local function dolt_query(sql)
	local host, port = dolt_config()
	local cmd = string.format(
		"mysql -h %s -P %d -u root hq -N -B -e %s 2>&1",
		host, port, vim.fn.shellescape(sql)
	)
	local out = vim.fn.system(cmd)
	if vim.v.shell_error ~= 0 then
		return nil, "mysql error: " .. vim.trim(out):sub(1, 200)
	end
	return vim.trim(out), nil
end

---Parse tab-separated mysql output into a list of row tables.
---@param output string Raw mysql -N -B output
---@param columns string[] Column names in order
---@return table[] rows
local function parse_tsv(output, columns)
	local rows = {}
	for line in (output .. "\n"):gmatch("([^\n]*)\n") do
		line = vim.trim(line)
		if line == "" then goto continue end
		local row = {}
		local i = 1
		for field in (line .. "\t"):gmatch("([^\t]*)\t") do
			row[columns[i] or tostring(i)] = field
			i = i + 1
		end
		table.insert(rows, row)
		::continue::
	end
	return rows
end

-- ============================================================================
-- Filesystem fallback helpers
-- ============================================================================

---List .formula.toml files in the formulas directory.
---@return string[] names Formula names (without .formula.toml suffix)
local function fs_list_names()
	local path = formulas_path()
	local files = vim.fn.glob(path .. "/*.formula.toml", false, true)
	local names = {}
	for _, f in ipairs(files) do
		local name = vim.fn.fnamemodify(f, ":t"):gsub("%.formula%.toml$", "")
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

---Read raw TOML content for a formula from filesystem.
---@param name string Formula name
---@return string|nil content, string|nil err
local function fs_read_toml(name)
	local path = formulas_path() .. "/" .. name .. ".formula.toml"
	local f, err = io.open(path, "r")
	if not f then
		return nil, "file not found: " .. path
	end
	local content = f:read("*a")
	f:close()
	return content, nil
end

---Parse a minimal subset of TOML (just [section] + key = "value" lines).
---Returns a flat table of {section.key = value}.
---@param toml string TOML content
---@return table
local function parse_toml_basic(toml)
	local result = {}
	local section = ""
	for line in (toml .. "\n"):gmatch("([^\n]*)\n") do
		-- Section header
		local sec = line:match("^%[([^%]]+)%]")
		if sec then
			section = sec
		else
			-- key = "value" or key = value
			local key, val = line:match('^([%w_]+)%s*=%s*"(.-)"')
			if not key then
				key, val = line:match("^([%w_]+)%s*=%s*(.+)")
			end
			if key and val then
				local full_key = section ~= "" and (section .. "." .. key) or key
				result[full_key] = val:match("^%s*(.-)%s*$")
			end
		end
	end
	return result
end

-- ============================================================================
-- Read API
-- ============================================================================

---@class FormulaMeta
---@field name string Formula name
---@field description string|nil
---@field version string|nil
---@field updated_at string|nil

---List all available formulas (names + basic metadata).
---Tries Dolt first, falls back to filesystem.
---@return FormulaMeta[] formulas
---@return string|nil err
function M.list()
	if dolt_available() then
		local sql = "SELECT name, description, version, updated_at FROM formulas ORDER BY name"
		local out, err = dolt_query(sql)
		if err then
			M._dolt_available = false -- disable for session on error
		elseif out then
			return parse_tsv(out, { "name", "description", "version", "updated_at" }), nil
		end
	end

	-- Filesystem fallback
	local names = fs_list_names()
	local result = {}
	for _, name in ipairs(names) do
		table.insert(result, { name = name })
	end
	return result, nil
end

---Read raw TOML content for a formula.
---@param name string Formula name
---@return string|nil toml Raw TOML string
---@return string|nil err
function M.read(name)
	if dolt_available() then
		local sql = string.format(
			"SELECT raw_toml FROM formulas WHERE name = %s LIMIT 1",
			vim.fn.shellescape(name):gsub("'", "'")
		)
		-- Use double-quotes for SQL string literals
		sql = string.format("SELECT raw_toml FROM formulas WHERE name = '%s' LIMIT 1", name:gsub("'", "''"))
		local out, err = dolt_query(sql)
		if err then
			M._dolt_available = false
		elseif out and out ~= "" then
			return out, nil
		end
	end

	return fs_read_toml(name)
end

---@class FormulaStep
---@field step_id string
---@field name string
---@field description string|nil
---@field position number|nil
---@field depends_on string[] Step IDs this step depends on

---Read structured formula data (steps, deps, vars, units) from Dolt.
---Returns nil if Dolt unavailable (use read() for filesystem fallback).
---@param name string Formula name
---@return table|nil structured
---@return string|nil err
function M.read_structured(name)
	if not dolt_available() then
		return nil, "Dolt unavailable — use M.read() for filesystem fallback"
	end

	-- Steps
	local steps_sql = string.format(
		"SELECT step_id, name, description, position FROM formula_steps WHERE formula_name = '%s' ORDER BY position",
		name:gsub("'", "''")
	)
	local steps_out, err = dolt_query(steps_sql)
	if err then
		return nil, err
	end
	local steps = parse_tsv(steps_out or "", { "step_id", "name", "description", "position" })

	-- Deps
	local deps_sql = string.format(
		"SELECT step_id, depends_on FROM formula_deps WHERE formula_name = '%s'",
		name:gsub("'", "''")
	)
	local deps_out, _ = dolt_query(deps_sql)
	local deps_map = {} -- step_id → []depends_on
	for _, row in ipairs(parse_tsv(deps_out or "", { "step_id", "depends_on" })) do
		deps_map[row.step_id] = deps_map[row.step_id] or {}
		table.insert(deps_map[row.step_id], row.depends_on)
	end
	for _, step in ipairs(steps) do
		step.depends_on = deps_map[step.step_id] or {}
		step.position = tonumber(step.position)
	end

	-- Vars
	local vars_sql = string.format(
		"SELECT name, default_value, description FROM formula_vars WHERE formula_name = '%s'",
		name:gsub("'", "''")
	)
	local vars_out, _ = dolt_query(vars_sql)
	local vars = parse_tsv(vars_out or "", { "name", "default_value", "description" })

	-- Units
	local units_sql = string.format(
		"SELECT unit_name, description FROM formula_units WHERE formula_name = '%s'",
		name:gsub("'", "''")
	)
	local units_out, _ = dolt_query(units_sql)
	local units = parse_tsv(units_out or "", { "unit_name", "description" })

	return { steps = steps, vars = vars, units = units }, nil
end

---List formula steps only.
---@param name string Formula name
---@return FormulaStep[]
---@return string|nil err
function M.steps(name)
	local structured, err = M.read_structured(name)
	if err or not structured then
		return {}, err
	end
	return structured.steps, nil
end

---List formula variables.
---@param name string Formula name
---@return table[]
---@return string|nil err
function M.vars(name)
	local structured, err = M.read_structured(name)
	if err or not structured then
		return {}, err
	end
	return structured.vars, nil
end

---List formula units.
---@param name string Formula name
---@return table[]
---@return string|nil err
function M.units(name)
	local structured, err = M.read_structured(name)
	if err or not structured then
		return {}, err
	end
	return structured.units, nil
end

-- ============================================================================
-- Write API
-- ============================================================================

---Save (upsert) a formula's raw TOML to Dolt.
---@param name string Formula name
---@param toml string TOML content
---@return boolean success
---@return string|nil err
function M.save(name, toml)
	if not dolt_available() then
		return false, "Dolt unavailable"
	end
	-- Escape single quotes for SQL
	local safe_name = name:gsub("'", "''")
	local safe_toml = toml:gsub("'", "''")
	local sql = string.format(
		"INSERT INTO formulas (name, raw_toml, updated_at) VALUES ('%s', '%s', NOW())"
			.. " ON DUPLICATE KEY UPDATE raw_toml='%s', updated_at=NOW()",
		safe_name, safe_toml, safe_toml
	)
	local _, err = dolt_query(sql)
	if err then
		return false, err
	end
	return true, nil
end

-- ============================================================================
-- Execution tracking (basic stubs)
-- ============================================================================

---List recent formula runs from Dolt.
---@param name string Formula name
---@param limit? number Max runs to return (default 10)
---@return table[] runs
---@return string|nil err
function M.runs(name, limit)
	if not dolt_available() then
		return {}, "Dolt unavailable"
	end
	limit = limit or 10
	local sql = string.format(
		"SELECT id, formula_name, status, started_at, completed_at FROM formula_runs"
			.. " WHERE formula_name = '%s' ORDER BY started_at DESC LIMIT %d",
		name:gsub("'", "''"), limit
	)
	local out, err = dolt_query(sql)
	if err then
		return {}, err
	end
	return parse_tsv(out or "", { "id", "formula_name", "status", "started_at", "completed_at" }), nil
end

---Get detail for a specific formula run.
---@param run_id string Run ID
---@return table|nil detail
---@return string|nil err
function M.run_detail(run_id)
	if not dolt_available() then
		return nil, "Dolt unavailable"
	end
	local sql = string.format(
		"SELECT step_id, status, output, started_at, completed_at FROM formula_run_items"
			.. " WHERE run_id = '%s' ORDER BY started_at",
		run_id:gsub("'", "''")
	)
	local out, err = dolt_query(sql)
	if err then
		return nil, err
	end
	return parse_tsv(out or "", { "step_id", "status", "output", "started_at", "completed_at" }), nil
end

return M
