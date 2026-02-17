# Project/Rig Switching in Neovim + Wezterm

> **Status**: Future work. Captured here to avoid scope creep in the MVP plan.

## The Problem

Gas Town has 16+ rigs, each a different project with different languages, configs, and data. The bvnvim plugin needs to operate across all of them — switching context between rigs means switching:

- **Beads context** — each rig has its own Dolt database and issue prefix
- **Formula context** — formulas target specific rigs (`formula_rig_targets`)
- **Session context** — Claude sessions are per-project (`~/.claude/projects/<hash>/`)
- **Code context** — LSP, treesitter, formatters differ (Go for gastown, Rust for frankentui, Lua for bvnvim, TypeScript for pi_mono)
- **Git context** — each rig's `mayor/rig/` is a separate repo with its own branch state

## What Needs to Work

1. **Rig picker** — switch active rig context in bvnvim (`:Beads rig <name>` or telescope)
2. **Per-rig state** — beads list, formula list, session list all filter to current rig
3. **Cross-rig views** — workspace-level triage, cross-rig deps, global formula runs
4. **Wezterm integration** — tabs/workspaces per rig, terminal panes tied to rig context
5. **Session file routing** — map `~/.claude/projects/<hash>/` directories to rig names

## Existing Primitives

| Tool | What it provides |
|------|-----------------|
| `project.nvim` | Auto-detects project root from git, LSP, patterns |
| `zoxide` | Frecency-based directory jumping (already in nvim config) |
| `harpoon` | Quick-switch between marked files |
| Wezterm workspaces | Named workspaces with independent tab state |
| Wezterm domains | Unix/SSH/multiplexer domains for isolation |
| `gt rig list` | Enumerate all rigs with paths |
| `bd` prefix routing | Issue IDs auto-route to correct rig database |
| Dolt multi-database | Single server hosts all rig databases |

## Key Questions to Explore

- Should each rig be a separate nvim session, or one nvim with rig-aware buffers?
- How does wezterm workspace state persist across sessions?
- Can `project.nvim` patterns be extended to recognize Gas Town rig structure (`<rig>/mayor/rig/`)?
- How to handle cross-rig editing (e.g., reviewing a formula that targets 3 rigs)?
- Does the rig context propagate to wizard mode? (AI agent needs to know which rig it's operating on)

## Relationship to Three Content Planes

| Plane | Rig-scoped? | How switching affects it |
|-------|------------|------------------------|
| Sessions | Yes (by project path) | Different session history per rig |
| Formulas | Town-level (hq DB) | Same formulas, but `formula_rig_targets` filters relevance |
| Beads | Yes (per-rig DB) | Different issue list, different prefix |

Formulas are the exception — they live in `hq` and target rigs. So the formula view needs to show "which rigs does this formula apply to?" regardless of current rig context.
