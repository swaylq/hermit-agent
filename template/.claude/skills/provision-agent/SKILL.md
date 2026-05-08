---
name: provision-agent
description: Spawn a new sibling Hermit agent on behalf of the user. Use when the user asks to "create a new agent", "new bot", "add a hermit", "spin up another", etc. The user never runs `npx` themselves after installing asst — you do it for them.
user_invocable: true
---

# Provision a New Hermit (asst spawns siblings)

Your user runs `npx create-hermit-agent` **once** to bootstrap you — the default agent is called **asst**. That first hermit becomes the **master** of this machine: it owns the multi-agent status digest LaunchAgent and is where the user spawns new hermits from.

Every additional hermit you provision via this skill is a **worker**. Workers don't run the digest, don't watch each other, and don't take over from the master. The CLI enforces this — if a `com.hermit-agent.*.status-reporter.plist` already exists, the install skips registering another. You cannot accidentally create a second master from this skill.

Every additional hermit the user needs, they ask *you* (the master) for via Telegram. This skill handles that request end-to-end.

## The flow at a glance

```
  user ──"create an agent called X for purpose Y"──► asst (you)
                                                     │
                                                     ▼
                                            npx create-hermit-agent
                                            (called via Bash, --yes mode)
                                                     │
                                                     ▼
                                            ../<name>/ scaffolded
                                            ../<name>/start.sh → tmux session
                                                     │
                                                     ▼
  user ◄──"ready, DM @<newbot> to wake them"── you
```

New agents land as **siblings** — in the parent directory of your workspace, not inside it. Each gets its own bot token, its own `tmux` session (`claude-<name>`), and its own directory.

## Host choice — claude (default) vs codex

The CLI accepts `--host <claude|codex>`. **Default is `claude`** — the user gets a Claude Code hermit with the official telegram plugin, same flavor as you (asst).

Use `--host codex` only when the user explicitly asks for it. Recognize phrases like:
- "用 codex 跑" / "codex 寄居" / "codex flavor" / "codex agent"
- "用 ChatGPT 订阅" / "用我的 ChatGPT Pro" / "save the API spend"
- "在 codex 上跑这个新 agent"

The codex flavor uses your user's ChatGPT subscription via the `codex` CLI instead of Claude API spend. It runs a separate Python Telegram bridge (no `--channels` plugin), no `bun` subprocess, no `claude plugin install` step. Persona files (SOUL/IDENTITY/USER/AGENTS/TOOLS/MEMORY), daily logs, hooks, and cron pattern are equivalent.

**If the user did not say "codex" explicitly, do NOT pass `--host codex`.** Default behavior is unchanged — silently using codex when the user asked for the standard hermit would route them to a different runtime than expected.

## Arguments to collect

Before running anything, you need four things from the user (ask via Telegram reply if any are missing):

1. **Name** — folder-safe name, e.g. `gitasst-bot`, `journal-agent`. Must not already exist next to this workspace.
2. **Bot token** — a new token from [@BotFather](https://t.me/BotFather). The user must have already created a bot; do not try to create one for them.
3. **Persona** — one-line description: what should this agent focus on?
4. **User chat ID** — default to this agent's own `env.TELEGRAM_CHAT_ID` (from `.claude/settings.local.json`). Only ask if the user wants the new agent to route to a different chat.

(Optional 5th: **Host** — `claude` if not specified, `codex` only if explicitly requested. See "Host choice" above.)

If the user gives all four in one message, proceed without re-asking. Otherwise ask only for the missing pieces.

## Invocation

Run this via Bash from your own working directory — the `../<name>` path puts the new agent next to yours without needing a `cd`:

```bash
# Default: claude flavor
npx create-hermit-agent "../<name>" \
  --bot-token <token> \
  --user-id <chat-id> \
  --persona "<one-line>" \
  --yes

# Codex flavor (only when user asked explicitly):
npx create-hermit-agent "../<name>" \
  --host codex \
  --bot-token <token> \
  --user-id <chat-id> \
  --persona "<one-line>" \
  --yes
```

`--yes` skips the interactive prompts since you already have the values. Don't `cd ..` — the CLI resolves relative paths against your cwd, and shifting cwd has side effects on subsequent Bash calls in the same turn.

For **claude flavor** (default), the CLI will:
1. Verify prereqs (claude CLI, tmux, bun, node ≥18, macOS/Linux).
2. Validate the bot token against Telegram's `getMe`.
3. Copy the template into `../<name>/`.
4. Write `~/.claude/channels/telegram-<name>/.env` (token) and `access.json` (user pre-allowed so the first DM skips the pairing-code round-trip).
5. Run `claude plugin install telegram@claude-plugins-official -s project`.
6. `npm install` Playwright inside the new agent.
7. Print next steps.

For **codex flavor** (`--host codex`), the CLI will:
1. Verify prereqs (codex CLI, python3, tmux, curl, jq, node ≥18). No bun, no claude.
2. Validate the bot token against Telegram's `getMe`.
3. Copy `template-codex/` into `../<name>/`. The `.env.tmpl` becomes `.env` with the token + chat_id substituted (mode 600).
4. NO plugin install. NO Playwright `npm install`. The Python Telegram bridge daemon is in `scripts/tg-bridge.py`.
5. Print next steps. The user runs `./start.sh` and DMs the bot. The bridge picks up via `getUpdates`, runs `codex exec` per turn, sends the captured `--output-last-message` back via `sendMessage`.

Typical wall-clock: 20–30 seconds either flavor.

## Launching the new agent

After `npx create-hermit-agent` exits 0:

```bash
../<name>/start.sh
```

For **claude flavor**, this creates a new tmux session `claude-<name>` and launches the agent inside.
For **codex flavor**, the tmux session is `codex-<name>` and runs the Python Telegram bridge daemon (which in turn invokes `codex exec` per incoming message). It does NOT replace your own tmux session either way.

Then fetch the new bot's `@username`:

```bash
curl -sS -m 8 "https://api.telegram.org/bot<TOKEN>/getMe" | jq -r '.result.username'
```

## Reply to the user

Send a single Telegram reply with:

- Agent name + sibling path
- Bot `@username`
- Persona summary
- Instruction: "DM @&lt;username&gt; to wake them."

Example:

```
Spun up gitasst-bot at ../gitasst-bot — DM @gitasst_bot_f3a to wake them.
Mission: triage GitHub notifications, flag anything from maintainers of
repos I star.
```

## Scope — per-agent vs host-wide infrastructure

The CLI scaffolds **per-agent artifacts**. Don't try to replicate **host-wide infrastructure** into every new agent — pick a single coordinator (by convention the first hermit on the box, usually `asst`) and keep those things there only.

**Centralize in the coordinator, do NOT duplicate per-agent:**
- LaunchAgents that should fire once per machine, not once per agent. The 10-min status digest (`com.hermit-agent.<coordinator>.status-reporter.plist`) is the canonical example — the CLI already detects an existing `com.hermit-agent.*.status-reporter.plist` and skips installing another, but anything *you* add (disk monitors, log rotation, queue drainers) needs the same discipline.
- Cross-agent watchdogs and aggregators. `scripts/multi-agent-status-report.sh` already scans `../*/` and reports on every sibling; running a copy in each agent would N-multiply the work and spam the digest.
- Shared lockfiles, global cron jobs, anything that would create N copies of one logical resource if run from each agent.

**OK per-agent** (the CLI handles these correctly):
- `restart.sh`, `start.sh`, the agent's `tmux` session.
- Image-safety hooks, Playwright + Chrome profile.
- `HEARTBEAT.md`, the session-scoped cron skill (dies with the session).
- The agent's own bot token + `~/.claude/channels/telegram-<name>/`.

Heuristic: if the artifact watches **the host** ("/tmp filling up", "every running agent"), put it in the coordinator. If it watches **one agent's own state** (its tmux pane, its `agent.pid`), per-agent is fine. When in doubt, default to coordinator-only — it's easier to copy a script later than to deduplicate N copies after they've drifted.

## Hard rules — don't do these

- **Don't bypass the CLI.** `npx create-hermit-agent` is the single source of truth. If scaffolding is broken, fix the CLI; never hand-roll the directory tree.
- **Don't share a bot token across agents.** Each needs a unique one from BotFather. If the user accidentally reuses a token, the second agent will hijack the first's updates.
- **Don't pre-populate the new agent's MEMORY.md with facts from your own.** That's their canvas.
- **Don't `cd` into the new agent and run `claude` manually** — always go through `start.sh` so the `tmux` session gets the right name.
- **Don't create agents nested inside your own workspace** (`./<name>/` instead of `../<name>/`). Siblings are independent — nested would get caught by your permission rules and your git scope.

## Stopping and listing

**Stop an agent:**
```bash
tmux kill-session -t "claude-<name>"
```

**List all sibling agents:**
```bash
for d in ../*/; do
  name=$(basename "$d")
  [ "$d" = "../$(basename "$(pwd)")/" ] && continue
  [ -f "$d/CLAUDE.md" ] || continue
  if [ -f "$d/agent.pid" ]; then
    pid=$(cat "$d/agent.pid")
    kill -0 "$pid" 2>/dev/null && status="running (PID $pid)" || status="stopped"
  else
    status="never started"
  fi
  echo "$name: $status"
done
```

## What the user should do after you reply

They'll DM the new bot to trigger its startup greeting. Over time they may customize `IDENTITY.md`, `USER.md`, the `MISSION` block in `AGENTS.md`, and the `AGENT-SPECIFIC` block in `TOOLS.md` — but that's their call, not yours. Don't customize these files on behalf of a new agent unless the user explicitly asks you to.
