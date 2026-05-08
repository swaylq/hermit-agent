# SKILLS.md — codex-demo skill index

Codex CLI doesn't load skills the same way Claude Code does (`.claude/skills/<name>/SKILL.md` with frontmatter loaded into the session). This directory is a documentation-only convention so the agent (and humans) know what capabilities the workspace exposes.

A skill here is one of two shapes:

1. **Shell-callable skill** — a folder containing `SKILL.md` (description) plus a `run.sh` (or similar). The agent reads `SKILL.md` to understand what it does, then invokes `run.sh` via shell when needed.
2. **MCP-tool skill** — registered as an MCP server in `~/.codex/config.toml` under `[mcp_servers.<name>]`. Codex calls it as a tool. The folder here contains only `SKILL.md` documenting where the actual server lives and how to enable it.

## Available

- `restart/` — restart the bridge daemon (see `restart/SKILL.md`)
- `provision-agent/` — placeholder for "create another codex hermit" tooling (see `provision-agent/SKILL.md`)

## Adding a new skill

1. `mkdir scripts/skills/<name>`
2. Write `SKILL.md` with: trigger keywords, what it does, side effects, how to invoke.
3. If shell-callable, drop `run.sh` and `chmod +x`.
4. If MCP-tool, register in `~/.codex/config.toml` and just document the binding here.

No auto-load machinery yet — the agent reads `SKILLS.md` proactively at session start (per `AGENTS.md` startup order, when this file becomes part of it). Future iteration may add auto-discovery.
