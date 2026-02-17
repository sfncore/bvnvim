---@mod bvnvim.data.sessions Session transcript data layer
---@brief [[
---Reads Claude Code session JSONL files from ~/.claude/projects/.
---
---JSONL schema (relevant entry types):
---  user:      {type, message: {role, content: string|list}, uuid, timestamp, sessionId, cwd}
---  assistant: {type, message: {role, content: [{type:"text",text:string}|{type:"thinking",...}]}, uuid, timestamp}
---  system:    {type, subtype, timestamp, ...}   — metadata / init
---  progress:  {type, data, ...}                 — tool use progress (skipped in transcript)
---
---API:
---  M.list_sessions(project_path?)  → session metadata list
---  M.extract_transcript(path)      → markdown string
---  M.search_sessions(query, opts?) → {path, line, text}[] matches
---  M.build_index(opts?)            → session metadata index (rig/bead correlation)
---  M.sessions_for_bead(id)         → session metadata list
---  M.sessions_for_rig(name)        → session metadata list
---@brief ]]

local M = {}

-- ============================================================================
-- Helpers
-- ============================================================================

---Get sessions root path from plugin config (falls back to default)
---@return string
local function sessions_root()
	local ok, bvnvim = pcall(require, "bvnvim")
	if ok and bvnvim.state and bvnvim.state.config and bvnvim.state.config.sessions_path then
		return bvnvim.state.config.sessions_path
	end
	return vim.fn.expand("~/.claude/projects")
end

---Read a file and return its content lines
---@param path string Absolute file path
---@return string[]|nil lines, string|nil err
local function read_lines(path)
	local f, err = io.open(path, "r")
	if not f then
		return nil, err
	end
	local lines = {}
	for line in f:lines() do
		table.insert(lines, line)
	end
	f:close()
	return lines, nil
end

---Parse a JSONL line, returning the decoded table or nil
---@param line string
---@return table|nil
local function parse_line(line)
	line = line:match("^%s*(.-)%s*$") -- trim
	if line == "" then
		return nil
	end
	local ok, result = pcall(vim.json.decode, line)
	if ok and type(result) == "table" then
		return result
	end
	return nil
end

---Extract plain text from a message content field
---Content may be a plain string or an array of content items.
---@param content string|table
---@return string
local function content_to_text(content)
	if type(content) == "string" then
		return content
	end
	if type(content) ~= "table" then
		return ""
	end
	local parts = {}
	for _, item in ipairs(content) do
		if type(item) == "string" then
			table.insert(parts, item)
		elseif type(item) == "table" then
			local itype = item.type or ""
			if itype == "text" and item.text then
				table.insert(parts, item.text)
			end
			-- Skip: thinking, tool_use, tool_result, image, etc.
		end
	end
	return table.concat(parts, "\n")
end

-- ============================================================================
-- M.list_sessions
-- ============================================================================

---@class SessionMeta
---@field uuid string Session UUID (from filename)
---@field path string Absolute path to JSONL file
---@field project string Project directory name
---@field size number File size in bytes
---@field mtime number File modification time (Unix epoch)
---@field first_ts string|nil ISO timestamp of first message
---@field last_ts string|nil ISO timestamp of last message
---@field cwd string|nil Working directory from first entry
---@field n_turns number Approximate turn count (user entries)

---List all session files under a project directory, newest first.
---@param project_path? string Path to scan (defaults to sessions_root())
---@return SessionMeta[] sessions
---@return string|nil err
function M.list_sessions(project_path)
	project_path = project_path or sessions_root()

	-- Find all *.jsonl files under project_path (one level deep for project dirs)
	local found = vim.fn.glob(project_path .. "/*/*.jsonl", false, true)

	-- Also check for JSONL files directly in project_path (flat layout)
	local flat = vim.fn.glob(project_path .. "/*.jsonl", false, true)
	for _, p in ipairs(flat) do
		table.insert(found, p)
	end

	if #found == 0 then
		return {}, nil
	end

	local sessions = {}
	for _, path in ipairs(found) do
		-- UUID is filename without extension
		local uuid = vim.fn.fnamemodify(path, ":t:r")
		-- Project dir name
		local project = vim.fn.fnamemodify(path, ":h:t")
		-- File stats
		local stat = vim.loop.fs_stat(path)
		local size  = stat and stat.size or 0
		local mtime = stat and stat.mtime.sec or 0

		-- Peek at first and last lines for timestamps
		local lines, _ = read_lines(path)
		local first_ts, last_ts, cwd
		local n_turns = 0

		if lines then
			-- First relevant entry
			for _, line in ipairs(lines) do
				local entry = parse_line(line)
				if entry and entry.timestamp and entry.type ~= "file-history-snapshot" then
					first_ts = first_ts or entry.timestamp
					if entry.cwd then
						cwd = cwd or entry.cwd
					end
					if entry.type == "user" then
						n_turns = n_turns + 1
					end
				end
			end
			-- Last timestamp: scan backwards
			for i = #lines, 1, -1 do
				local entry = parse_line(lines[i])
				if entry and entry.timestamp and entry.type ~= "file-history-snapshot" then
					last_ts = entry.timestamp
					break
				end
			end
		end

		table.insert(sessions, {
			uuid      = uuid,
			path      = path,
			project   = project,
			size      = size,
			mtime     = mtime,
			first_ts  = first_ts,
			last_ts   = last_ts,
			cwd       = cwd,
			n_turns   = n_turns,
		})
	end

	-- Sort newest first (by mtime)
	table.sort(sessions, function(a, b)
		return a.mtime > b.mtime
	end)

	return sessions, nil
end

-- ============================================================================
-- M.extract_transcript
-- ============================================================================

---@class TranscriptEntry
---@field role "user"|"assistant"|"system"
---@field text string Message text
---@field timestamp string|nil ISO timestamp
---@field uuid string|nil Message UUID

---Extract a human-readable transcript from a JSONL session file.
---Returns a markdown string with labelled turns.
---@param path string Absolute path to the JSONL file
---@return string markdown Formatted conversation
---@return string|nil err
function M.extract_transcript(path)
	local lines, err = read_lines(path)
	if not lines then
		return "", err
	end

	local entries = {} ---@type TranscriptEntry[]

	for _, line in ipairs(lines) do
		local entry = parse_line(line)
		if not entry then goto continue end

		local t = entry.type
		if t == "user" then
			local msg = entry.message or {}
			local text = content_to_text(msg.content or "")
			if text ~= "" then
				table.insert(entries, {
					role      = "user",
					text      = text,
					timestamp = entry.timestamp,
					uuid      = entry.uuid,
				})
			end

		elseif t == "assistant" then
			local msg = entry.message or {}
			local text = content_to_text(msg.content or "")
			if text ~= "" then
				table.insert(entries, {
					role      = "assistant",
					text      = text,
					timestamp = entry.timestamp,
					uuid      = entry.uuid,
				})
			end

		elseif t == "system" and (entry.subtype == "init" or entry.subtype == "start") then
			local ts = entry.timestamp or ""
			table.insert(entries, {
				role      = "system",
				text      = "Session started" .. (ts ~= "" and (" at " .. ts:sub(1, 19)) or ""),
				timestamp = entry.timestamp,
				uuid      = entry.uuid,
			})
		end

		::continue::
	end

	-- Render to markdown
	local out = {}
	for _, e in ipairs(entries) do
		local ts_str = ""
		if e.timestamp then
			-- ISO → human: "2026-02-17T08:30:00.000Z" → "08:30"
			ts_str = " _" .. (e.timestamp:match("T(%d%d:%d%d)") or e.timestamp:sub(1, 16)) .. "_"
		end

		if e.role == "user" then
			table.insert(out, "## User" .. ts_str)
			table.insert(out, "")
			table.insert(out, e.text)
			table.insert(out, "")
		elseif e.role == "assistant" then
			table.insert(out, "## Claude" .. ts_str)
			table.insert(out, "")
			table.insert(out, e.text)
			table.insert(out, "")
		elseif e.role == "system" then
			table.insert(out, "---")
			table.insert(out, "_" .. e.text .. "_")
			table.insert(out, "")
		end
	end

	return table.concat(out, "\n"), nil
end

-- ============================================================================
-- M.search_sessions
-- ============================================================================

---@class SearchMatch
---@field path string JSONL file path
---@field uuid string Session UUID
---@field line_num number 1-indexed line number in file
---@field role string Entry type (user/assistant)
---@field text string The matching text snippet (up to 120 chars)
---@field timestamp string|nil

---Search for a query string across session files.
---Uses simple substring matching (case-insensitive).
---@param query string Text to search for
---@param opts? table Options: project_path, limit (default 50)
---@return SearchMatch[] matches
---@return string|nil err
function M.search_sessions(query, opts)
	opts = opts or {}
	local limit = opts.limit or 50
	local sessions, err = M.list_sessions(opts.project_path)
	if err then
		return {}, err
	end

	local query_lower = query:lower()
	local matches     = {}

	for _, session in ipairs(sessions) do
		if #matches >= limit then
			break
		end

		local lines, _ = read_lines(session.path)
		if not lines then goto next_session end

		for i, line in ipairs(lines) do
			local entry = parse_line(line)
			if not entry then goto next_line end

			local t = entry.type
			if t ~= "user" and t ~= "assistant" then goto next_line end

			local msg  = entry.message or {}
			local text = content_to_text(msg.content or "")
			if text:lower():find(query_lower, 1, true) then
				-- Truncate snippet around the match
				local idx  = text:lower():find(query_lower, 1, true) or 1
				local start = math.max(1, idx - 40)
				local snippet = text:sub(start, start + 119)
				table.insert(matches, {
					path      = session.path,
					uuid      = session.uuid,
					line_num  = i,
					role      = t,
					text      = snippet,
					timestamp = entry.timestamp,
				})
				if #matches >= limit then
					break
				end
			end
			::next_line::
		end
		::next_session::
	end

	return matches, nil
end

-- ============================================================================
-- M.build_index / correlation helpers
-- ============================================================================

-- Module-level index cache
M._index = nil

---Build a session index with rig and bead correlations.
---Scans cwd fields in session entries to detect which rig/bead a session belongs to.
---@param opts? table Options: project_path, gt_root (default ~/gt)
---@return SessionMeta[] index
---@return string|nil err
function M.build_index(opts)
	opts = opts or {}
	local gt_root = opts.gt_root or vim.fn.expand("~/gt")

	local sessions, err = M.list_sessions(opts.project_path)
	if err then
		return {}, err
	end

	for _, session in ipairs(sessions) do
		local cwd = session.cwd or ""

		-- Detect rig from cwd: ~/gt/<rig>/...
		local rig = cwd:match(vim.pesc(gt_root) .. "/([^/]+)")
		session.rig = rig

		-- Detect bead from cwd worktree paths: .../<rig>/.gt/worktrees/<bead-id>/...
		local bead_id = cwd:match("worktrees/([a-z][a-z0-9]*%-[a-z0-9]+)")
		session.bead_id = bead_id
	end

	M._index = sessions
	return sessions, nil
end

---Get sessions associated with a specific bead ID.
---Builds index if not already built.
---@param id string Bead ID (e.g. "bv-lj7")
---@return SessionMeta[]
function M.sessions_for_bead(id)
	if not M._index then
		M.build_index()
	end
	local results = {}
	for _, s in ipairs(M._index or {}) do
		if s.bead_id == id then
			table.insert(results, s)
		end
	end
	return results
end

---Get sessions associated with a specific rig.
---Builds index if not already built.
---@param name string Rig name (e.g. "bvnvim", "sfgastown")
---@return SessionMeta[]
function M.sessions_for_rig(name)
	if not M._index then
		M.build_index()
	end
	local results = {}
	for _, s in ipairs(M._index or {}) do
		if s.rig == name then
			table.insert(results, s)
		end
	end
	return results
end

return M
