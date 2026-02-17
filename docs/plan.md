# bvnvim: Neovim Beads Viewer/Editor Plugin (MVP)

## Context

We're building a Neovim plugin that operates on **three content planes** — the full audit trail of the startup factory system. Each plane has its own storage, access method, and display strategy. The key innovation is "wizard mode" — an AI agent drives edits visually via Neovim's RPC API while the human watches. This is the first module of a broader vision: Neovim as a token-efficient AI execution substrate for a startup factory.

**What exists:**
- `bvnvim` rig (sfncore/bvnvim) — empty, ready for plugin code
- `nvim_config` rig (sfncore/nvim-config, symlinked to `~/.config/nvim/`) — LazyVim setup
- `claudecode.nvim` — already provides MCP tools for Claude-Neovim integration
- `bv` CLI — rich `--robot-*` JSON API (triage, plan, priority, insights, graph, search)
- `bd` CLI — beads write operations (update, close, create)
- `pynvim` 0.6.0 — Python RPC client for Neovim (already installed)
- `undofile` enabled, persisting to `~/.vim/undodir/`
- `cchistory` CLI — lists shell command history from Claude Code session logs
- 89 Claude Code session JSONL files at `~/.claude/projects/*/`
- 52 formula TOMLs at `~/gt/.beads/formulas/`

**Critical — beadswrangler's Dolt integration (sfncore/beads_viewer fork, not yet upstream):**
- `pkg/loader/dolt.go` — **Dolt SQL backend** for live beads loading (queries issues, deps, labels, comments directly from Dolt server at 127.0.0.1:3307)
- `pkg/triage/branch.go` — **Dolt branch triage engine**: creates branch → runs analysis → proposes changes (reprioritize, add deps, flag stale) → commits to branch → generates diff report → TUI/agent reviews and merges
- `pkg/workspace/routes.go` — **Auto-discover rigs** from `routes.jsonl` (no manual workspace.yaml needed)
- `pkg/ui/triage_diff_modal.go` — **TUI diff view** for reviewing proposed changes
- `--dolt` flag enables live Dolt loading; `--triage-rig` triggers branch triage workflow

---

## The Three Content Planes

The audit trail runs across three independent versioning systems. Each plane has different storage, different access patterns, and different display needs in Neovim.

### Plane 1: Agent Session Transcripts

**What**: Full agent-to-human conversation logs from Claude Code sessions. Every tool call, every response, every decision — the "why" behind every change.

**Storage**: Claude Code session JSONL files
- Location: `~/.claude/projects/<project-hash>/<session-uuid>.jsonl`
- 89 sessions across all projects (mayor, beadswrangler, crew, rigs)
- Format: One JSON object per line, keyed by `type`:
  - `type=user` → `entry.message.content` (string, the human's message)
  - `type=assistant` → `entry.message.content` (array of text/tool_use blocks)
  - `type=progress` → streaming/tool execution progress
  - `type=system` → system prompts, context injection
  - `type=file-history-snapshot` → file state at that point
- **Not yet fully explored** — need to map: what metadata is available per session? Can we link sessions to rigs? To specific beads? How does cchistory index this data?

**Access**:
- `cchistory` CLI — shell command history extraction (limited: commands only, not full conversation)
- Direct JSONL parsing — for full transcript extraction
- **Exploration needed**: Build or find a proper session transcript API that can:
  - List sessions by project/date/rig
  - Extract human ↔ agent conversation (strip tool internals)
  - Link sessions to beads they worked on (via `bd` commands in the log)
  - Produce clean markdown transcripts for nvim display

**Display in Neovim**:
- Read-only markdown buffer showing conversation flow
- Collapsible tool call sections (show/hide internals)
- Highlight: human messages vs agent responses vs tool calls
- URI scheme: `session://<session-uuid>` or `session://<project>/<date>`
- Telescope picker: search sessions by date, project, content

**Write-back**: None. Transcripts are append-only audit logs. No mutations.

**Exploration tasks**:
1. Map the full JSONL schema (all entry types, all fields)
2. Determine how to correlate sessions → rigs → beads (parse bd/gt commands from logs)
3. Evaluate cchistory source code for reuse vs writing our own parser
4. Design the transcript rendering format (what to show, what to collapse)
5. Prototype a session list → session detail flow in nvim

### Plane 2: Formulas (Dolt-stored)

**What**: Workflow definitions that encode the startup factory's processes. Each formula is a directed graph of steps — from simple 3-step workflows to complex 7-step analysis pipelines like `cockpit-feed.formula.toml` (which runs 13 bv algorithms per rig + 4 cross-rig algorithms). Four formula types: convoy (parallel legs + synthesis), workflow (sequential steps), expansion (template-based), aspect (multi-aspect parallel).

**Storage**: Dolt SQL database (migrated from filesystem), normalized across creation and execution phases.

- **Source of truth**: `hq` database at `127.0.0.1:3307` — formulas are town-level, not per-rig
- **Filesystem becomes cache**: `~/gt/.beads/formulas/` regenerated from Dolt on `gt install` or `gt formula sync`
- `.installed.json` becomes redundant — Dolt IS the version tracker
- **Migration**: Import 52 existing TOMLs → parse and normalize into Dolt tables
- **Existing code**: `internal/formula/parser.go` parses TOML via `github.com/BurntSushi/toml`; `embed.go` handles provisioning; `cmd/formula.go` runs CLI commands. Parser needs a Dolt loading path alongside the filesystem path.
- **Branch workflows**: Draft formula changes on a Dolt branch, review diffs in nvim (`dolt diff main..draft`), merge when approved. Same pattern as beadswrangler's triage branches for beads.

**Schema — Phase 1: Creation/Definition (the DNA)**

```sql
-- ═══════════════════════════════════════════════════════════
-- Core formula metadata
-- ═══════════════════════════════════════════════════════════
CREATE TABLE formulas (
    name         VARCHAR(128) PRIMARY KEY,
    type         VARCHAR(32) NOT NULL,      -- convoy/workflow/expansion/aspect
    version      INT NOT NULL DEFAULT 1,
    description  TEXT,
    source_repo  VARCHAR(512),              -- origin: sfncore/sf-gastown, Xexr/gt-toolkit, etc.
    raw_toml     LONGTEXT,                  -- original TOML source for round-trip editing
    updated_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ═══════════════════════════════════════════════════════════
-- Workflow steps + Expansion templates (same shape)
-- ═══════════════════════════════════════════════════════════
CREATE TABLE formula_steps (
    formula_name VARCHAR(128) NOT NULL,
    step_id      VARCHAR(64) NOT NULL,
    title        VARCHAR(256),
    description  TEXT,                       -- includes embedded bash/SQL code blocks
    parallel     BOOLEAN DEFAULT FALSE,      -- workflow only: can run concurrently
    sort_order   INT NOT NULL DEFAULT 0,
    PRIMARY KEY (formula_name, step_id),
    FOREIGN KEY (formula_name) REFERENCES formulas(name)
);

-- Step/template dependencies (needs)
CREATE TABLE formula_step_deps (
    formula_name VARCHAR(128) NOT NULL,
    step_id      VARCHAR(64) NOT NULL,
    depends_on   VARCHAR(64) NOT NULL,
    PRIMARY KEY (formula_name, step_id, depends_on),
    FOREIGN KEY (formula_name, step_id) REFERENCES formula_steps(formula_name, step_id)
);

-- ═══════════════════════════════════════════════════════════
-- Variables (workflow) + Inputs (convoy) — unified
-- ═══════════════════════════════════════════════════════════
CREATE TABLE formula_vars (
    formula_name  VARCHAR(128) NOT NULL,
    var_name      VARCHAR(64) NOT NULL,
    var_kind      VARCHAR(16) NOT NULL,     -- 'var' (workflow) or 'input' (convoy)
    description   TEXT,
    var_type      VARCHAR(32),              -- convoy inputs: type field
    required      BOOLEAN DEFAULT FALSE,
    required_unless TEXT,                   -- convoy inputs: JSON array of input names
    default_val   VARCHAR(256),
    PRIMARY KEY (formula_name, var_name),
    FOREIGN KEY (formula_name) REFERENCES formulas(name)
);

-- ═══════════════════════════════════════════════════════════
-- Legs (convoy) + Aspects (aspect) — unified as "units"
-- ═══════════════════════════════════════════════════════════
CREATE TABLE formula_units (
    formula_name VARCHAR(128) NOT NULL,
    unit_id      VARCHAR(64) NOT NULL,
    unit_type    VARCHAR(16) NOT NULL,      -- 'leg' or 'aspect'
    title        VARCHAR(256),
    focus        TEXT,
    description  TEXT,
    sort_order   INT NOT NULL DEFAULT 0,
    PRIMARY KEY (formula_name, unit_id),
    FOREIGN KEY (formula_name) REFERENCES formulas(name)
);

-- ═══════════════════════════════════════════════════════════
-- Convoy prompts (named prompt templates)
-- ═══════════════════════════════════════════════════════════
CREATE TABLE formula_prompts (
    formula_name VARCHAR(128) NOT NULL,
    prompt_name  VARCHAR(64) NOT NULL,
    content      TEXT NOT NULL,
    PRIMARY KEY (formula_name, prompt_name),
    FOREIGN KEY (formula_name) REFERENCES formulas(name)
);

-- ═══════════════════════════════════════════════════════════
-- Convoy output config + synthesis
-- ═══════════════════════════════════════════════════════════
CREATE TABLE formula_output (
    formula_name VARCHAR(128) PRIMARY KEY,
    directory    VARCHAR(256),
    leg_pattern  VARCHAR(256),
    synthesis    VARCHAR(256),
    FOREIGN KEY (formula_name) REFERENCES formulas(name)
);

CREATE TABLE formula_synthesis (
    formula_name VARCHAR(128) PRIMARY KEY,
    title        VARCHAR(256),
    description  TEXT,
    FOREIGN KEY (formula_name) REFERENCES formulas(name)
);

CREATE TABLE formula_synthesis_deps (
    formula_name VARCHAR(128) NOT NULL,
    depends_on   VARCHAR(64) NOT NULL,
    PRIMARY KEY (formula_name, depends_on),
    FOREIGN KEY (formula_name) REFERENCES formula_synthesis(formula_name)
);

-- ═══════════════════════════════════════════════════════════
-- Rig targeting — which rigs can this formula operate on
-- ═══════════════════════════════════════════════════════════
CREATE TABLE formula_rig_targets (
    formula_name VARCHAR(128) NOT NULL,
    rig_name     VARCHAR(64) NOT NULL,      -- matches gt rig list
    PRIMARY KEY (formula_name, rig_name),
    FOREIGN KEY (formula_name) REFERENCES formulas(name)
);
```

**Schema — Phase 2: Cooked & Poured (execution history)**

```sql
-- ═══════════════════════════════════════════════════════════
-- Execution runs — when a formula was cooked and poured
-- Links formula DNA → beads it spawned → branches it used
-- ═══════════════════════════════════════════════════════════
CREATE TABLE formula_runs (
    id            INT AUTO_INCREMENT PRIMARY KEY,
    formula_name  VARCHAR(128) NOT NULL,
    formula_ver   INT NOT NULL DEFAULT 1,   -- version at time of run
    rig_name      VARCHAR(64),              -- target rig
    epic_bead_id  VARCHAR(255),             -- epic bead created (→ issues.id)
    branch_name   VARCHAR(128),             -- dolt/git branch used
    started_at    TIMESTAMP,
    completed_at  TIMESTAMP,
    status        VARCHAR(32) NOT NULL      -- running/completed/failed/cancelled
                  DEFAULT 'running',
    run_by        VARCHAR(255),             -- agent or human who ran it
    metadata      JSON,                     -- extra context (vars used, error info)
    FOREIGN KEY (formula_name) REFERENCES formulas(name),
    INDEX idx_formula (formula_name),
    INDEX idx_rig (rig_name),
    INDEX idx_epic (epic_bead_id),
    INDEX idx_status (status)
);

-- ═══════════════════════════════════════════════════════════
-- Per-step/leg execution — maps formula units to beads
-- Links structural DNA → the actual beads each piece became
-- ═══════════════════════════════════════════════════════════
CREATE TABLE formula_run_items (
    id            INT AUTO_INCREMENT PRIMARY KEY,
    run_id        INT NOT NULL,
    item_id       VARCHAR(64) NOT NULL,     -- step_id, leg unit_id, or 'synthesis'
    bead_id       VARCHAR(255),             -- bead created for this item (→ issues.id)
    status        VARCHAR(32) NOT NULL      -- pending/running/completed/failed/skipped
                  DEFAULT 'pending',
    started_at    TIMESTAMP,
    completed_at  TIMESTAMP,
    FOREIGN KEY (run_id) REFERENCES formula_runs(id),
    INDEX idx_run (run_id),
    INDEX idx_bead (bead_id)
);
```

**Linking to existing Gas Town structures:**

| Formula table | Links to | Relationship |
|---------------|----------|-------------|
| `formulas.source_repo` | Git origin | Where the formula came from (embedded, community, user) |
| `formula_rig_targets` | Rigs (`gt rig list`) | Which rigs this formula can target |
| `formula_runs.epic_bead_id` | `issues.id` | The epic bead spawned by pouring |
| `formula_runs.branch_name` | Dolt/git branches | Integration or triage branch used |
| `formula_runs.rig_name` | Rigs | Which rig the run targeted |
| `formula_run_items.bead_id` | `issues.id` | Each step/leg becomes a bead |
| `issues.spec_id` | `formulas.name` | Epic bead references its formula (reverse link) |

**Access**:
- Primary: Dolt SQL query (`SELECT content FROM formulas WHERE name = ?`)
- Fallback: filesystem cache at `~/gt/.beads/formulas/` (for offline or pre-migration)
- `gt formula list` — enumerate formulas (will query Dolt once migrated)
- `gt formula run <name>` — execute a formula
- `gt formula sync` — export Dolt → filesystem cache (new command needed)

**Display in Neovim**:
- TOML editing with tree-sitter highlighting (already works in LazyVim)
- Custom rendering for formula-specific structure:
  - Step dependency graph visualization (ascii or extmark-based, computed from `needs` fields)
  - Step status overlay when a formula is running (via RPC from gt)
  - Variable substitution preview (`{{var}}` → resolved value)
  - Embedded code block highlighting (bash/SQL inside TOML string values)
- URI scheme: `formula://<name>` → loads content from Dolt, opens as TOML buffer
- Telescope picker: search formulas by name, type, step count
- **Dolt diff view**: `:Beads formula diff <name>` → shows changes between branches

**Write-back**: `buftype = "acwrite"` with `BufWriteCmd` interceptor. `:w` in a `formula://` buffer:
1. Parses the buffer content as TOML (validates structure)
2. Computes SHA256 hash
3. `UPDATE formulas SET content = ?, hash = ?, updated_at = NOW() WHERE name = ?`
4. Optionally auto-commits: `CALL DOLT_COMMIT('-am', 'Update formula: <name>')`
5. Updates filesystem cache

**Implementation tasks**:
1. Dolt schema creation — create all 12 formula tables in `hq` database
2. Migration script — parse 52 existing TOMLs, normalize into all tables (formulas + steps + deps + vars + units + prompts + output + synthesis + rig_targets), preserve `raw_toml`
3. Formula data module — Dolt SQL read/write for both definition (DNA) and execution (cooked & poured) phases, filesystem fallback
4. Formula buffer — TOML editing with step graph overlay, acwrite interceptor normalizes to Dolt on save
5. Execution history view — show formula runs, per-step bead mapping, clickable bead IDs
6. Formula telescope picker — browse by name/type, preview step structure + last run status
7. Formula diff view — structural Dolt diffs between branches (not just text)
8. `gt formula sync` — export Dolt → filesystem cache for backward compat
9. Formula branch workflow — create/review/merge formula changes on Dolt branches
10. Wire `gt formula run` to record execution in `formula_runs` + `formula_run_items` tables

### Plane 3: Materialized Beads

**What**: The actual issue tracking data — beads (tasks, bugs, features, epics) stored in Dolt. This is the largest plane: 7K+ issues across all rigs, with dependencies, labels, comments, and AI-computed analysis (triage scores, execution plans, forecasts).

**Storage**: Dolt SQL database
- Server: `127.0.0.1:3307`, data in `~/gt/.dolt-data/`
- One database per rig (e.g., `sfgastown`, `hq`, `frankentui`)
- Also available as JSONL exports via `bd sync --flush-only`
- Beadswrangler's Dolt integration enables live SQL queries and branch-based triage

**Access — two tiers**:

Tier 1: `bd` CLI for raw bead data (fast, simple):
- `M.list(opts)` — `bd list --json --status=X --rig=Y` → array of `{id, title, status, priority, issue_type, owner, assignee, created_at, ...}`
- `M.show(id)` — `bd show <id> --json` → single bead with full deps

Tier 2: `bv` CLI for smart analysis (rich, heavier):
- `M.triage(opts)` — `bv --robot-triage --format json --dolt` → scored recommendations, quick wins, blockers, project health
- `M.plan()` — `bv --robot-plan --format json --dolt` → dependency-respecting execution tracks
- `M.search(query)` — `bv --robot-search --search "query" --format json --dolt` → semantic search
- `M.insights()` — `bv --robot-insights --format json --dolt` → graph analysis
- Add `--workspace .bv/workspace.yaml` for cross-rig views

**Write-back — two speeds**:

Quick edits (single bead via `bd` CLI):
- `M.update(id, fields)` — `bd update <id> --status X --priority Y`
- `M.close(id, reason)` — `bd close <id>`
- `M.create(fields)` — `bd create --title "..." --type task`

Bulk edits (Dolt branch triage workflow):
- `bv --triage-rig <rig> --dolt` → creates Dolt branch with proposed changes
- Human reviews diffs in nvim → accepts/rejects per proposal
- Merge accepted changes from triage branch to main

**Display in Neovim**:
- List view: fixed-column table with priority colors, status highlights
- Detail view: structured header + markdown body, `:w` intercepted for write-back
- Triage diff view: side-by-side proposed changes with accept/reject
- URI scheme: `bead://<id>` for individual beads
- Telescope picker: fuzzy search across ID + title + assignee

---

## The Audit Stack

Every action is tracked at three independent levels:

| Plane | Versioning | Branching | Diffable | Persistent | What it captures |
|-------|-----------|-----------|----------|------------|-----------------|
| Transcripts | Append-only JSONL | Per-session | N/A | Yes | The "why" — decisions, reasoning |
| Formulas | Dolt (hq DB) | Yes | Yes | Yes | The "how" — workflow definitions |
| Beads | Dolt (per-rig DB) | Yes | Yes | Yes | The "what" — work state, proposals |
| Edits | Neovim undo tree | DAG | Yes | Yes (undofile) | The "when" — keystroke-level history |

Formulas and beads now share the same versioning substrate (Dolt) but live in different databases — formulas in `hq` (town-level), beads in per-rig databases. The fourth layer (Neovim undo tree) cuts across all three planes — every edit in every buffer is tracked in the persistent undo DAG at `~/.vim/undodir/`.

---

## Plugin File Structure

```
/home/ubuntu/gt/bvnvim/mayor/rig/
  lua/
    bvnvim/
      init.lua           -- setup(), commands, state
      config.lua         -- defaults, validation
      data/
        beads.lua        -- bd CLI wrapper (list, show, update, close, create)
        analysis.lua     -- bv CLI wrapper (triage, plan, insights, search)
        formulas.lua     -- formula TOML loader (list, read, resolve search path)
        sessions.lua     -- session JSONL parser (list, extract transcript)
      buffer/
        beads_list.lua   -- bead list view rendering
        beads_detail.lua -- bead detail view rendering
        formula.lua      -- formula TOML enhanced view
        session.lua      -- session transcript view
        triage_diff.lua  -- triage proposal diff view
      highlight.lua      -- highlight groups, extmarks (all planes)
      actions.lua        -- status/priority/assignee changes, write-back
      wizard.lua         -- wizard mode state, RPC handler, sequencer
    telescope/
      _extensions/
        bvnvim.lua       -- telescope picker (beads, formulas, sessions)
  scripts/
    wizard_driver.py     -- external Python RPC wizard driver
```

Registration in nvim_config:
```
/home/ubuntu/gt/nvim_config/mayor/rig/lua/plugins/bvnvim.lua
```

## Implementation Steps

### Step 1: Core plugin skeleton (`init.lua`, `config.lua`)
- `M.setup(opts)` — merge config, register `:Beads` command with subcommands
- Commands spanning all three planes:
  - `:Beads list` / `:Beads show <id>` / `:Beads refresh` — materialized beads
  - `:Beads formula [name]` — formula browser/viewer
  - `:Beads session [uuid]` — session transcript viewer
  - `:Beads wizard start|stop` — wizard mode
- State table: `{ config, current_rig, beads_cache, formula_cache, session_index, buffers }`
- Config defaults: `{ gt_root = "~/gt", formulas_path = "~/gt/.beads/formulas", sessions_path = "~/.claude/projects", default_rig = nil }`

### Step 2: Data layer — Materialized Beads (`data/beads.lua`, `data/analysis.lua`)

**`data/beads.lua`** — raw bead CRUD via `bd` CLI:
- `M.list(opts)` — `bd list --json --status=X --rig=Y`
- `M.show(id)` — `bd show <id> --json`
- `M.update(id, fields)` — `bd update <id> --status X --priority Y`
- `M.close(id, reason)` — `bd close <id>`
- `M.create(fields)` — `bd create --title "..." --type task`

**`data/analysis.lua`** — smart analysis via `bv` CLI:
- `M.triage(opts)` — `bv --robot-triage --format json --dolt`
- `M.plan()` — `bv --robot-plan --format json --dolt`
- `M.search(query)` — `bv --robot-search --search "query" --format json --dolt`
- `M.insights()` — `bv --robot-insights --format json --dolt`

Uses `vim.fn.system()` for sync, `vim.fn.jobstart()` for async.

### Step 3: Data layer — Formulas (`data/formulas.lua`)

**Definition reads (Phase 1 — the DNA):**
- `M.list()` — query `SELECT name, type, version, description, source_repo FROM hq.formulas` → array
- `M.read(name)` — query `SELECT raw_toml FROM hq.formulas WHERE name = ?` → TOML string for editing
- `M.read_structured(name)` — JOINs across `formulas`, `formula_steps`, `formula_step_deps`, `formula_vars`, `formula_units` → full structured object for rendering step graphs, previews
- `M.steps(name)` — query `formula_steps` + `formula_step_deps` → step list with dependency graph
- `M.units(name)` — query `formula_units` → legs (convoy) or aspects (aspect)
- `M.vars(name)` — query `formula_vars` → variables/inputs with defaults
- `M.rig_targets(name)` — query `formula_rig_targets` → which rigs this formula can target
- `M.diff(name, branch)` — compare formula tables between Dolt branches (structural diff, not just text)

**Definition writes (editing DNA):**
- `M.save(name, toml_content)` — parse TOML, validate, normalize into all tables (formulas + steps + deps + vars + units + prompts + output + synthesis), then `CALL DOLT_COMMIT(...)`
- `M.create(name, toml_content)` — INSERT across all normalized tables
- `M.delete(name)` — CASCADE delete across all formula tables

**Execution reads (Phase 2 — cooked & poured):**
- `M.runs(name)` — query `formula_runs WHERE formula_name = ?` → execution history
- `M.run_detail(run_id)` — query `formula_runs` + `formula_run_items` → per-step/leg bead mapping
- `M.runs_for_rig(rig_name)` — all formula runs targeting a specific rig
- `M.runs_for_bead(bead_id)` — find which formula run spawned a bead (reverse lookup)

**Execution writes (recording pours):**
- `M.start_run(name, rig, run_by)` — INSERT into `formula_runs`, return run_id
- `M.record_item(run_id, item_id, bead_id)` — INSERT into `formula_run_items`
- `M.complete_run(run_id, status)` — UPDATE `formula_runs` with completion

**Access:**
- Dolt SQL via `vim.fn.system('dolt --host 127.0.0.1 --port 3307 ...')` or `vim.fn.jobstart()` for async
- Fallback: filesystem read from `~/gt/.beads/formulas/` if Dolt unavailable
- TOML parsing: `vim.fn.system("toml2json ...")` or a pure-lua TOML parser for client-side validation

### Step 4: Data layer — Sessions (`data/sessions.lua`)

**Exploration task — this module requires research before full implementation.**

What we know:
- Session JSONL files at `~/.claude/projects/<project-hash>/<session-uuid>.jsonl`
- Entry format: `{type, message, ...}` where type ∈ {user, assistant, progress, system, file-history-snapshot}
- `cchistory` CLI extracts shell commands only (not full conversation)
- We successfully extracted a 51KB transcript from one session using a Python script

What we need to explore:
1. **Schema mapping**: Document all entry types and their field structures. What metadata exists per session (start time, project, model, token counts)?
2. **Session ↔ rig correlation**: Can we link a session to the rig it worked in? Parse `gt prime` output or `bd` commands from the log to determine the rig context.
3. **Session ↔ bead correlation**: Can we find which beads a session worked on? Scan for `bd show`, `bd update`, `bd close`, `gt sling` commands in the session.
4. **Transcript extraction**: Build a Lua function that parses JSONL and produces a clean conversation transcript (human messages, agent responses, tool call summaries — not raw tool internals).
5. **Index building**: Design an index that maps sessions → {project, rig, date, beads_touched, duration, model} for fast Telescope searching.
6. **cchistory evaluation**: Read cchistory source to determine if any of its parsing logic is reusable, or if we need our own parser.

Initial implementation (enough for MVP):
- `M.list_sessions(project_path)` — scan JSONL files, extract basic metadata (uuid, modified time, file size)
- `M.extract_transcript(session_path)` — parse JSONL → markdown transcript
- `M.search_sessions(query)` — grep across session files for content matches

Full implementation (post-exploration):
- `M.build_index()` — scan all sessions, extract rig/bead/date metadata, cache to disk
- `M.sessions_for_bead(bead_id)` — find all sessions that touched a specific bead
- `M.sessions_for_rig(rig_name)` — find all sessions that worked in a specific rig

### Step 5: Buffer rendering — Beads (`buffer/beads_list.lua`, `buffer/beads_detail.lua`, `highlight.lua`)

**List view** — fixed-column table format:
```
# Beads: sfgastown (24 open)                     [R]efresh [F]ilter
──────────────────────────────────────────────────────────────────────
 ID          P  Status       Type     Title
──────────────────────────────────────────────────────────────────────
 st-a1b2     P0 open         task     Fix auth timeout bug
 st-c3d4     P1 in_progress  feature  Add voice control layer
```

Fixed columns enable wizard mode to target fields by position. Line-to-bead mapping stored in `vim.b[bufnr].bvnvim_line_map`.

**Detail view** — structured header + markdown body:
```
# st-a1b2: Fix auth timeout bug
──────────────────────────────────
Status:      open
Priority:    P0
Type:        task
Assignee:
──────────────────────────────────

## Description
...
```

- Buffer uses `buftype = "acwrite"` with `bead://<id>` URI scheme
- `:w` intercepted via `BufWriteCmd` to write back via `bd update`
- Highlight groups: `BvnvimP0`-`BvnvimP4` (priority colors), `BvnvimOpen`/`BvnvimInProgress`/`BvnvimCompleted` (status)

### Step 6: Buffer rendering — Formulas (`buffer/formula.lua`)

**Definition view** (`formula://<name>`):
- `BufReadCmd` loads `raw_toml` from Dolt (`data/formulas.lua.read()`)
- Buffer is real TOML with extmark decorations on top:
  - **Step dependency graph**: ASCII art or virtual text showing execution order derived from `formula_step_deps`
  - **Unit overview**: For convoy/aspect types, show legs/aspects with focus areas as virtual text
  - **Embedded code highlighting**: Detect bash/SQL code blocks inside TOML string values, apply tree-sitter injections
  - **Variable resolution**: Show `{{var}}` → resolved default values as virtual text
  - **Rig targets**: Virtual text showing which rigs this formula can target
- `buftype = "acwrite"` — `:w` intercepted via `BufWriteCmd`:
  1. Validates TOML structure (parse check)
  2. Normalizes into all tables via `data/formulas.lua.save()`
  3. Auto-commits to Dolt
  4. Updates filesystem cache at `~/gt/.beads/formulas/`

**Execution history view** (`formula-runs://<name>`):
- Shows all runs of this formula with status, rig, timestamps
- Each run expandable to show per-step/leg bead mapping
- Bead IDs are clickable — `<CR>` opens the bead detail view (`bead://<id>`)
- Connects the DNA to what it produced:
  ```
  # cockpit-feed — Execution History
  ──────────────────────────────────────────
  Run #3  2026-02-17 09:30  sfgastown  completed  (epic: st-xyz)
    ├─ discover-rigs   → st-abc  completed
    ├─ algo-sweep      → st-def  completed
    ├─ workspace-analysis → st-ghi  completed
    └─ write-feed      → st-jkl  completed

  Run #2  2026-02-16 14:00  frankentui  failed
    ├─ discover-rigs   → bd-mno  completed
    └─ algo-sweep      → bd-pqr  failed ✗
  ```

**Diff view** (`:Beads formula diff <name> [branch]`):
- Structural diff from Dolt — shows changes per table (steps added/removed, vars changed, etc.)
- Not just text diff of TOML blob — actual structural changes

### Step 7: Buffer rendering — Sessions (`buffer/session.lua`)

- Read-only markdown buffer showing conversation transcript
- Format:
  ```
  # Session: 36e0ffd3 — 2026-02-17 (mayor)
  ──────────────────────────────────────────

  ## Human (10:03 PM)
  im thinking to rewrite the frontend for bv...

  ## Agent (10:03 PM)
  Pretty deeply. The whole grammar — operators...

  ## Tool: Bash (10:04 PM)
  > gt rig add nvim https://github.com/neovim/neovim.git
  [collapsed output]

  ## Human (10:05 PM)
  ...
  ```
- Collapsible sections: tool calls fold by default, `zo`/`zc` to expand/collapse
- Highlight groups: `BvnvimHuman` (green), `BvnvimAgent` (blue), `BvnvimTool` (gray)
- URI scheme: `session://<uuid>`
- `buftype = "nofile"` — read-only, no write-back

### Step 8: Buffer rendering — Triage Diff (`buffer/triage_diff.lua`)

- Displays Dolt branch triage proposals from `bv --triage-rig`
- Format:
  ```
  # Triage: sfgastown (12 proposals)
  ──────────────────────────────────────────
  [✓] st-a1b2  priority  P2 → P0  (critical path score: 0.92)
  [ ] st-c3d4  status    open → stale  (no activity 30d)
  [✓] st-e5f6  dep_add   → st-g7h8  (suggested by graph analysis)
  ```
- Keymaps: `<Space>` toggle accept/reject, `<CR>` show detail, `M` merge accepted
- Proposals sourced from `bv --triage-rig <rig> --dolt --format json`

### Step 9: Actions (`actions.lua`)

**Quick edits (single bead):**
- List view keymaps: `s` (set status via `vim.ui.select`), `p` (set priority), `<CR>` (open detail), `q` (close buffer)
- Detail view: edit fields inline, `:w` triggers diff against cached original → `bd update` with changed fields only

**Bulk edits (Dolt branch triage workflow):**
- `:Beads triage <rig>` → opens triage diff view
- Accept/reject individual proposals
- `:Beads triage merge` → merges accepted changes from triage branch to main
- This is the AI-driven workflow: wizard mode operates on a triage branch, human reviews diffs, then merges

### Step 10: Telescope picker (`telescope/_extensions/bvnvim.lua`)

Three picker modes:
1. **Beads picker** (`:Telescope bvnvim beads`) — colored columns (ID, priority, status, type, title), `<CR>` opens detail view, fuzzy search across ID + title + assignee
2. **Formula picker** (`:Telescope bvnvim formulas`) — columns (name, type, version, steps, last_run, status), `<CR>` opens formula view, `<C-r>` opens execution history, preview shows step graph + rig targets
3. **Session picker** (`:Telescope bvnvim sessions`) — columns (date, project/rig, duration, size), `<CR>` opens transcript view, preview shows first few exchanges

Registered via `telescope.load_extension("bvnvim")`

### Step 11: Wizard mode (`wizard.lua`, `scripts/wizard_driver.py`)

**Lua side:**
- `:Beads wizard start` — enables wizard, prints socket path, registers global functions
- `_G.bvnvim_wizard_exec(commands, delay_ms)` — executes `:norm` commands with `vim.defer_fn` delays
- Cursor trail highlight via extmarks (`BvnvimWizardCursor`)
- Works across all three planes (beads editing, formula review, session navigation)

**Python driver (wizard_driver.py):**
- Connects via `pynvim.attach('socket', path=...)`
- `--demo` mode: navigates through beads, opens detail view (proves visual RPC works)
- `--update <id> --status <val>` mode: visually navigates to bead, changes status
- `--fast` mode: instant update via `nvim_buf_set_text` (no animation)
- `--batch <file.json>` mode: executes sequence of commands from JSON

### Step 12: LazyVim registration (`nvim_config/lua/plugins/bvnvim.lua`)
- `dir = "/home/ubuntu/gt/bvnvim/mayor/rig"` (local dev plugin)
- Dependencies: `plenary.nvim`, `telescope.nvim`
- Keymaps:
  - `<leader>bb` — beads list
  - `<leader>bs` — beads search (telescope)
  - `<leader>bf` — formula picker
  - `<leader>bh` — session history picker
  - `<leader>bt` — triage view
  - `<leader>bw` — wizard mode toggle

## Verification

**Plane 1 — Sessions:**
1. `:Beads session` — lists available sessions
2. `:Telescope bvnvim sessions` — fuzzy search sessions by date/project
3. Open a session → shows formatted conversation transcript
4. `zo`/`zc` — expand/collapse tool call sections

**Plane 2 — Formulas:**
5. `:Beads formula` — lists available formulas (from Dolt, not filesystem)
6. `:Telescope bvnvim formulas` — fuzzy search formulas, shows last run status
7. Open a formula → shows TOML with step graph overlay, rig targets, embedded code highlighting
8. `:w` on a formula → normalizes to Dolt tables + commits + updates filesystem cache
9. `:Beads formula runs <name>` → shows execution history with bead links
10. `:Beads formula diff <name>` → structural diff between Dolt branches

**Plane 3 — Beads:**
8. `:Beads list` — shows formatted table of beads with colors
9. `<CR>` on a bead — opens detail view
10. `s` on a bead line — changes status via select menu, persists via `bd`
11. `:Beads triage sfgastown` — opens triage diff view with proposals
12. Accept proposals → `:Beads triage merge` → changes applied

**Cross-plane:**
13. `:Beads wizard start` → run `python3 wizard_driver.py <socket> --demo` → watch cursor move through beads in real-time
14. `u` in Neovim — undoes wizard edits
15. `:UndotreeToggle` — shows all edits in the undo DAG

## Key Design Decisions

- **Three content planes**: Transcripts (audit), Formulas (workflow), Beads (work state) — each with its own storage, access, and display strategy
- **Two-tier reads for beads**: `bd` for raw lists (fast), `bv --robot-*` for smart analysis (triage, plan, search, insights). `bd` for single writes, Dolt branch triage for bulk.
- **Dolt branch workflow for AI bulk edits** — AI works on a triage branch (beadswrangler's `pkg/triage/branch.go`), proposes changes, human reviews diffs in nvim, then merges. No direct bulk mutations.
- **Session transcripts are read-only** — append-only audit logs, never mutated from nvim
- **Formulas stored in Dolt (normalized + raw)** — 12 tables in `hq` database: `formulas` (with `raw_toml`), `formula_steps`, `formula_step_deps`, `formula_vars`, `formula_units`, `formula_prompts`, `formula_output`, `formula_synthesis`, `formula_synthesis_deps`, `formula_rig_targets`, `formula_runs`, `formula_run_items`. Normalized tables enable structural diffs and cross-formula queries; `raw_toml` enables faithful round-trip editing. Filesystem becomes cache.
- **Two-phase formula tracking** — Phase 1 (DNA): formula definition with rig targets and source repo. Phase 2 (cooked & poured): execution history linking formula runs → epic beads → per-step/leg beads → agent sessions. Full audit circle.
- **Formula editing is native TOML** — enhanced with overlays, acwrite interceptor parses TOML → normalizes into all Dolt tables + updates `raw_toml` + commits
- **Fixed-column list format** — enables wizard targeting by column position
- **`buftype = "acwrite"`** — for beads detail view: intercepts `:w` for write-back while keeping undo tree working
- **pynvim for wizard driver** — already installed, runs as separate process (AI agent spawns it)
- **Two modes**: wizard (visual `:norm`) vs fast (`nvim_buf_set_text`) — same edits, different presentation
- **Depends on sfncore/beads_viewer fork** — need to pull Dolt integration commits before triage features work
- **Session exploration is a discrete task** — the JSONL schema and correlation logic need research before full implementation; MVP starts with basic transcript extraction

---

## Conversation History (Full Brainstorm)

### The Vision: Neovim as AI Execution Substrate

**Human:** I'm thinking to rewrite the frontend for bv as a LazyNvim plugin.

Actually I'm building out a core set of open source tech that can be composed into 100s of startups and I think nvim could be a core part of that stack.

It might be quite AI native too. How well do you understand vim motions?

**Mayor:** Pretty deeply. The whole grammar — operators (`d`, `c`, `y`), motions (`w`, `e`, `f`, `t`, `%`), text objects (`iw`, `a"`, `ip`), registers, marks, macros, visual modes, ex commands. It's a composable language I can think in natively.

Vim motions are basically a well-defined, token-efficient DSL for manipulating text. An AI agent that speaks vim natively could drive Neovim directly with far less overhead than shipping whole file rewrites through tool calls.

### Dolt + Git + Neovim: Version Control All the Way Down

**Human:** Now think about dolt branches and merging like the work we did yesterday on bv and the harness article we read while doing the pi work about diffs.

**Mayor:** The composable stack:

| Layer | Component | Role |
|-------|-----------|------|
| Storage | Dolt | Branching, merging, diffing structured data |
| Edit | Neovim + vim motions | Compact agent edit language |
| UI | Neovim plugins (Lua) | Terminal-native, composable views |
| Agents | AI speaking vim natively | Parallel work on branches, merge via diffs |

### Hashline Token Savings

**Human:** Now think about the hashline article about token savings with harness.

**Mayor:** Hashlines give you `LINE:HASH|content` — compact addressable lines where the AI targets edits by hash, not by quoting context. 5-14% better edit success, ~20% fewer output tokens.

Token savings stack multiplicatively:

| Layer | Saving | Mechanism |
|-------|--------|-----------|
| Hashlines | ~20% | Address by hash, not quoted context |
| Vim motions | ~90% | Tiny edit commands, not full rewrites |
| Dolt diffs | ~95% | Only changed rows, not full dumps |

**~1000x token efficiency gain** for bulk data operations at scale.

### Gas Town Formula System as Startup DNA

**Human:** The core piece for my startup factory system is going to be utilizing Gas Town's formula system which we will extend to manage the entire process from ideation/exploration through implementation & management. BV needed a workflow TUI already that can handle thousands of documents in the most efficient machine-friendly manner. And nvim is pretty close to the metal right?

**Mayor:** Neovim is extremely close to the metal. Terminal-native rendering, zero DOM overhead, handles thousands of buffers without breaking a sweat. Telescope/fzf can fuzzy-search through massive document sets in milliseconds.

The full picture:
- **Formulas are the startup DNA** — each formula encodes a workflow (ideation, exploration, implementation, management). The factory stamps out startups by composing formulas.
- **Neovim is the cockpit** — not a viewer, a workflow execution environment. Thousands of beads, docs, specs flowing through it.
- **Dolt is the memory** — every state change branched, diffable, mergeable.
- **Gas Town is the engine room** — agents executing formulas, polecats grinding through branches.

### Voice Control: The Product Category

**Human:** AI is moving towards voice control. Vim essentially mastered keyboard control. I think there is a product or three coming out of using nvim keymapping as a kind of shorthand for very fast AI automation commands via voice. So you can just talk to an AI and watch the nvim editor in real time orchestrating workflows across Gas Town visually using Lua and vim motions with nvim and wezterm.

**Mayor:** That's the piece that turns this from a power-user tool into a product category.

Vim mastered **composable keyboard grammar**. Voice AI needs a **composable spoken grammar**. They're the same thing.

You don't teach users vim. You let them **talk** and the AI translates intent into vim motions that execute visually in real-time. The user watches the cursor move, text change, windows split. It's not a black box — it's a live performance.

Three products:
1. **Voice-driven development** — speak intent, watch vim motions edit code
2. **Voice-driven ops dashboard** — talk to your infrastructure, watch it respond visually
3. **Voice-driven startup factory** — "spin up a fintech from the payments template, run the exploration formula" and watch Gas Town build it in real-time

The moat is **transparency**. Every other voice-AI tool is a black box. This one, you watch the AI's hands move.

### Audit Trail at Every Layer

**Human:** The transparency and tracking is baked in at the database and file level via dolt and git. But also down to the editing buffers with nvim.

**Mayor:** With `set undofile`, Neovim persists the undo tree to disk. The full branching DAG survives across sessions.

| Layer | Versioning | Branching | Diffable | Persistent |
|-------|-----------|-----------|----------|------------|
| Code | git | yes | yes | yes |
| Data | Dolt | yes | yes | yes |
| Edits | Neovim undo tree | yes (DAG) | yes | yes (undofile) |
| Session | Neovim shada/session | — | — | yes |

Three independent, persistent, branching audit trails covering every granularity from individual keystrokes to repository-wide changes. All diffable. All composable.

You're not building an audit system. You're composing one from tools that each solved their own versioning problem independently. That's regulatory-grade traceability out of the box.

### AI Doesn't Use Keys — It Uses Commands

**Human:** AI doesn't use keys?

**Mayor:** Right — AI agents don't press keys. They use tool calls. The real interface is Neovim's first-class **RPC API**.

| | File rewrite | Neovim RPC client |
|---|---|---|
| Context cost | Read entire file every time | Query specific lines/regions |
| Output cost | Emit full file or big diff | Tiny targeted commands |
| Feedback | None until done | Real-time, human watches |
| Reversibility | Hope you have git | `u` instantly |
| Error handling | Malformed JSON = broken file | Invalid command = no-op, buffer unchanged |

**Human:** It would use the commands.

**Mayor:** Right. `nvim_command(":%s/old/new/g")`, `nvim_command(":42")`, `nvim_command(":norm dw")`. Ex commands and normal-mode commands via the API. Every `nvim_command` call through the RPC socket is a discrete loggable event.

Neovim was already built as a server with a message protocol. The terminal UI is just one client. An AI agent is another client talking to the same server over the same RPC socket. First-class citizen, not a hack.

### Wizard Mode: Visual vs Fast

**Human:** Without using the keystrokes would you still get the visual effect of a neovim wizard editing?

**Mayor:** With raw API calls like `nvim_buf_set_text()` — no, text just appears changed. But with `nvim_command(":norm ...")` — yes. Normal-mode commands executed via RPC DO move the cursor, DO animate visually.

| Mode | Speed | Visual | Use case |
|------|-------|--------|----------|
| `nvim_buf_set_text` | Instant | Text teleports | Batch operations, speed matters |
| `:norm` commands | Real-time | Full cursor animation | Demos, voice-driven, human watching |
| `:norm` + delays | Theatrical | Dramatic wizard | Presentations, onboarding |

Product feature: "watch mode" where you see the AI work like a vim master, vs "fast mode" where it just gets it done.

### Rigs Created

- **nvim** rig (prefix `nv-`) — neovim/neovim source at latest master. For deep understanding and potential modification.
- **nvim_config** rig (prefix `nc-`) — sfncore/nvim-config. `~/.config/nvim` symlinked to `~/gt/nvim_config/mayor/rig/`. The factory's Neovim distribution.
- **bvnvim** rig (prefix `bv-`) — sfncore/bvnvim. The plugin itself.

### Nvim Config State

- LazyVim setup with Primeagen base
- `undofile = true`, persisting to `~/.vim/undodir/`
- undotree plugin installed (`<leader>u` to visualize DAG)
- claudecode.nvim installed (MCP tools, WebSocket server, diff support)
- Plugins: telescope, snacks, harpoon, fugitive, treesitter, project.nvim, which-key, zoxide

### Two Content Types in Nvim

**Human:** We need to discuss what we are editing and viewing in nvim — it's two things: 1) the .toml formulas from workflows and 2) the materialized beads.

**Mayor:**
1. **Formula TOMLs** (`~/gt/.beads/formulas/*.formula.toml`) — workflow definitions that define the entire bv analysis pipeline. The cockpit-feed formula alone runs 13 bv algorithms per rig + 4 cross-rig algorithms and materializes results into Dolt branches. Editing/reviewing these in nvim before running.
2. **Materialized beads** — the actual beads data that results from running those formulas. Triage proposals, priority scores, execution plans. Viewing/triaging these in nvim.

The nvim review step is where the human (or AI with human watching) inspects both — the formula that's about to run, and the results it produced. That's the auditability layer.

### Beadswrangler's Dolt Integration (sfncore/beads_viewer fork)

Key commits not yet upstream:
- `d79fbe0` — **Dolt SQL backend** for live beads loading (`pkg/loader/dolt.go`)
- `d1483ef` — **Dolt branch triage engine** (`pkg/triage/branch.go`): creates branch → runs analysis → proposes changes → commits to branch → generates diff report → TUI/agent reviews and merges
- `65b9510` — **Auto-discover rigs** from `routes.jsonl` (`pkg/workspace/routes.go`)
- `3ebf58b` — **`--dolt` standalone flag** for auto-discovery
- `feff0f8` — **Rig picker polish** with scrolling, counts, deselect all

The branch triage engine is the key primitive: AI proposes changes on a Dolt branch, human reviews diffs, then merges. This is exactly the workflow bvnvim should integrate with for bulk edits.
