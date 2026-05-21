<div align="center">

<img src="assets/logo.png" width="200" alt="Hermit Agent logo"/>

# Hermit Agent

**Not a standalone agent framework — a hermit crab that lodges inside an existing AI coding host. One command bootstraps a Telegram-connected agent with persona, long-term memory, scheduler, and browser automation. Default host is [Claude Code](https://docs.claude.com/claude-code); pass `--host codex` to lodge inside [OpenAI Codex CLI](https://developers.openai.com/codex/cli) and use a ChatGPT subscription instead of API spend.**

[English](README.md) · [中文](README.zh-CN.md)

[![npm](https://img.shields.io/npm/v/create-hermit-agent?style=flat-square)](https://www.npmjs.com/package/create-hermit-agent)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow?style=flat-square)](LICENSE)
[![Node 18+](https://img.shields.io/badge/node-18%2B-green?style=flat-square)](https://nodejs.org)
[![macOS](https://img.shields.io/badge/platform-macOS-blue?style=flat-square)](https://www.apple.com/macos/)
[![Claude Code](https://img.shields.io/badge/host-Claude_Code-orange?style=flat-square)](https://docs.claude.com/claude-code)
[![Codex CLI](https://img.shields.io/badge/host-Codex_CLI-black?style=flat-square)](https://developers.openai.com/codex/cli)

</div>

---

## Why a hermit crab?

Claude Code closes its third-party subscription surface, so I built an agent that **lodges inside its host CLI itself** — fusing the best ideas from three agent-harness frameworks. The default host is Claude Code; v0.1.38+ also supports Codex CLI as a sibling host (see [Host choice](#host-choice-claude-code-or-codex)).

| Borrowed from | What it contributed |
|---|---|
| **[Claude Code](https://docs.claude.com/claude-code)** | The default shell. Every agent literally runs inside `claude --dangerously-skip-permissions`. Plugins, MCP, tools, hooks — all native, nothing reimplemented. |
| **[Codex CLI](https://developers.openai.com/codex/cli)** _(opt-in via `--host codex`)_ | Alternative shell that piggybacks on a ChatGPT subscription. The hermit ships its own `scripts/tg-bridge.py` Python daemon that translates Telegram updates into `codex exec` calls, since Codex has no `--channels`-style plugin model. |
| **OpenClaw** | Self-managed-browser pattern. Shaped `scripts/chrome-launcher.sh`, `scripts/browser-lock.sh`, per-agent Chrome profile + CDP reuse, stealth-wrapped Playwright. |
| **Hermas Agent** | Autonomous-evolution pattern and memory-module design. `SOUL.md` + `MEMORY.md` + daily `memory/YYYY-MM-DD.md` logs + dream-style consolidation all inherited. |

---

## 30-second quickstart

**Default (Claude Code host):**

```bash
# Prereqs: Claude Code installed & logged in, Node 18+, brew install tmux jq, bun installed
npx create-hermit-agent
cd asst && ./start.sh
```

**Codex host** (uses your ChatGPT subscription, no API spend):

```bash
# Prereqs: codex CLI installed & `codex login` done, Node 18+, brew install tmux jq, python3
npx create-hermit-agent my-agent --host codex
cd my-agent && ./start.sh
```

> **Linux**: same flow, with `sudo apt install tmux jq curl` (or your distro's equivalent) and `loginctl enable-linger $USER` for systemd-user timers. Linux scaffolds ship a deliberately reduced surface — no browser, no image-safety layer. See the [Install](#install) and [FAQ](#faq) sections.

Open Telegram, DM the bot you just registered with @BotFather. First DM triggers a one-shot orientation — then the agent stays out of your way.

> **You:** remind me at 3pm to call mom  
> **asst:** scheduled — I'll ping you at 3pm today.

---

## Feature matrix

| Capability | Detail |
|---|---|
| **Host choice** | `--host claude` (default) or `--host codex`. Claude flavor uses the `@claude-plugins-official/telegram` plugin and the full Claude Code shell. Codex flavor uses a Python Telegram bridge daemon and your ChatGPT subscription via `codex exec`. Same persona files, same memory pattern, same hook layout. |
| **Persona** | `SOUL / IDENTITY / USER / AGENTS / TOOLS / MEMORY.md` loaded every session. Edit the files → edit the agent. Codex auto-loads `AGENTS.md` natively; Claude Code loads via `CLAUDE.md`. |
| **Long-term memory** | Daily logs at `memory/YYYY-MM-DD.md`, curated long-term at `MEMORY.md`. Survives restarts. |
| **Telegram I/O** | _Claude flavor_: native reply / react / edit / attachment download via `@claude-plugins-official/telegram`. Plain English or Chinese routes to slash commands ("压缩上下文" → `/compact`, "重启" → `restart.sh`). _Codex flavor_: Python bridge daemon polls `getUpdates`, runs `codex exec [resume <thread>]` per turn, posts text + auto-detected generated images via `sendPhoto`. Daemon-level admin commands: `/help` `/status` `/reset` `/restart`. |
| **Lifecycle** | `start.sh` + `restart.sh` wrap the agent in a named `tmux` session — `claude-<name>` (claude flavor) or `codex-<name>` (codex flavor). Both flavors persist state across restarts. |
| **Scheduler** | Three tiers — session-only `cron` skill, cross-restart `HEARTBEAT.md`, OS-durable `launchd` plists. Codex flavor uses `scripts/run-cron.sh` wrapping `codex exec` with `with-timeout.sh 1200`. |
| **Browser** | Dedicated Chrome profile + CDP + Playwright + stealth-init anti-detection (claude flavor). Codex flavor relies on the bundled `browser-use` plugin instead. |
| **Multi-agent** | `provision-agent` skill spawns siblings at `../<name>/` with their own bot tokens. The skill recognizes "用 codex / 用 ChatGPT 订阅" and passes `--host codex` through; default stays claude. Optional 10-min digest LaunchAgent. |
| **Safety** | Images forced through `safe-image.sh` resize (≤1800px long edge). Tokens stored at mode 600 outside the repo. _Claude flavor_: Stop hook blocks turn-end if a Telegram DM got no reply; PreToolUse hook strips markdown from outbound replies. _Codex flavor_: equivalent guardrails via `scripts/hooks/{boot,pre-run,post-run}.sh` — boot fires `FIRST_RUN.md`, pre-run runs `safe-image.sh` on detected paths, post-run strips markdown + writes daily log. |

---

## Host choice: Claude Code or Codex

Pass `--host` to the CLI. Default is `claude`.

```bash
npx create-hermit-agent my-agent                 # claude (default)
npx create-hermit-agent my-agent --host codex    # codex
```

| | Claude flavor (`--host claude`) | Codex flavor (`--host codex`) |
|---|---|---|
| **Underlying CLI** | `claude --dangerously-skip-permissions --channels plugin:telegram@…` (long-running REPL, Telegram messages stream in via the plugin's `--channels` channel) | `codex exec --json --output-last-message <file> [resume <thread_id>]` (one-shot per turn, daemon orchestrates) |
| **Cost model** | Anthropic API tokens (claude.ai Pro for the CLI plus per-token billing for plugin sessions) | ChatGPT subscription (Plus / Pro / Team / Enterprise — codex CLI consumes the subscription's request budget directly) |
| **Telegram bridge** | Native — the official `@claude-plugins-official/telegram` plugin runs as a `bun` MCP subprocess inside the claude session and pushes Telegram updates straight into the REPL as new turns | External Python daemon (`scripts/tg-bridge.py`, ~250 lines, stdlib-only) long-polls `getUpdates`, invokes `codex exec` per turn, posts captured `--output-last-message` back via `sendMessage`. Auto-detects new pngs in `~/.codex/generated_images/<thread>/` and forwards via `sendPhoto`. |
| **Lifecycle hooks** | Claude Code's native hooks: `SessionStart` / `Stop` / `PreToolUse` / `UserPromptSubmit` declared in `.claude/settings.json` | `scripts/hooks/{boot,pre-run,post-run}.sh` invoked by the bridge daemon. boot ≈ SessionStart, pre-run ≈ UserPromptSubmit, post-run ≈ Stop. pre-run exit ≠ 0 aborts the turn; post-run stdout replaces the reply (markdown strip / redaction). |
| **Slash / admin commands** | Plain English / Chinese routes via `scripts/exec-cli-command.sh` ("压缩" → `/compact`, "重启" → `restart.sh $(cat agent.pid)`) | Daemon intercepts `/help` `/status` `/reset` `/restart` directly without invoking codex |
| **Skills** | Auto-loaded from `.claude/skills/` (Claude Code's native skill protocol) | Documented in `scripts/skills/` (no auto-loader yet — agent reads `SKILLS.md` proactively or invokes via shell). Codex's bundled plugins (`browser-use`, `documents`, `presentations`, `spreadsheets`) are available alongside. |
| **MCP servers** | Per-agent in `.claude/settings.local.json` | Per-user in `~/.codex/config.toml` `[mcp_servers.<id>]` |
| **Cron / scheduler** | `claude --dangerously-skip-permissions -p "<prompt>"` (caveat: plugin sync doesn't fire under `-p`) | `scripts/run-cron.sh <task>` reads `cron/<task>.md`, `codex exec` it under `with-timeout.sh 1200`, posts result to Telegram via direct curl |
| **State** | `agent.pid` + Claude Code session in `~/.claude/projects/…` | `state/thread.txt` (current codex thread UUID), `state/update_id.txt` (last Telegram update_id) — both in workspace root, restart-safe |

When to pick which:

- **Claude** — you want the official `--channels` integration, slash commands, the full Claude Code skill ecosystem, and you're willing to pay per-token.
- **Codex** — you already pay for ChatGPT and want to redirect that subscription at agent workloads. You're OK with the polling-bridge model (every turn is a fresh `codex exec` invocation; threads are persisted via `~/.codex/sessions/`). You don't need the Claude-specific plugin marketplace.

Mixing is fine — one machine can run both flavors side-by-side. Each gets its own `tmux` session and its own bot token.

---

## Architecture

```
┌────────────── Your Mac ──────────────┐       ┌─ Telegram ─┐
│                                       │       │            │
│  tmux session   claude-asst           │       │  Bot API   │
│  ┌───────────────────────────────┐   │       │            │
│  │  claude  (the borrowed shell)  │   │       │            │
│  │  ┌────────┐  ┌───────────────┐ │   │       │            │
│  │  │Persona │  │ Skills + Hooks│ │   │◄─────►│ @yourbot   │
│  │  │*.md    │  │ restart · cron│ │   │       │            │
│  │  │memory/ │  │ provision ... │ │   │       │            │
│  │  └────────┘  └───────────────┘ │   │       │            │
│  │     Telegram plugin (bun)      │   │       │            │
│  └────────────────────────────────┘   │       │            │
│                                       │       │            │
│  ~/.claude/channels/telegram-asst/    │       │            │
│    (bot token — not in the repo)       │       │            │
└───────────────────────────────────────┘       └────────────┘
```

Higher-res SVG: [assets/arch.svg](assets/arch.svg).

---

## Install

Prereqs (macOS, **claude flavor**):

- [Claude Code](https://docs.claude.com/claude-code) — installed and logged in (`claude login`)
- Node ≥ 18
- `brew install tmux jq`
- `curl -fsSL https://bun.sh/install | bash`

Prereqs (macOS, **codex flavor**):

- [Codex CLI](https://developers.openai.com/codex/cli) — installed and logged in (`codex login`, ChatGPT account; `codex login status` should say "Logged in using ChatGPT")
- Node ≥ 18
- `python3` (system or via `brew install python3`)
- `brew install tmux jq curl`

Prereqs (Linux, tested on Ubuntu 22.04, claude flavor):

- [Claude Code](https://docs.claude.com/claude-code) — installed and logged in
- Node ≥ 18
- `sudo apt install tmux jq curl` (or `dnf` / `pacman` / `apk` equivalent)
- `curl -fsSL https://bun.sh/install | bash`
- One-time on a server: `loginctl enable-linger $USER` so `systemd --user` timers survive logout

The Linux scaffold ships **without the browser layer** (chrome-launcher, browser-lock, playwright-mcp) and **without the image-safety layer** (safe-image, pre-read-image hook). Both are macOS-shaped (sips, .app paths) and porting them is out of scope for v1 — the CLI strips them automatically on Linux. Everything else (Telegram plugin, persona, memory, scheduling, multi-agent status digest) works the same. **Codex flavor on Linux** is also supported but tested less thoroughly — file an issue if anything breaks.

Scaffold:

```bash
# Claude flavor (default)
npx create-hermit-agent

# Codex flavor
npx create-hermit-agent my-agent --host codex
```

The CLI asks for a Telegram bot token ([@BotFather](https://t.me/BotFather)) and your own Telegram user ID ([@userinfobot](https://t.me/userinfobot)).

- **Claude flavor**: creates `./asst/`, installs the Telegram plugin at project scope, writes the token to `~/.claude/channels/telegram-asst/.env` (mode 600).
- **Codex flavor**: creates `./my-agent/`, writes `.env` (mode 600) with the token and chat_id directly inside the workspace, copies the Python bridge daemon and hooks. No plugin install — the Telegram bridge is a self-contained Python script. AGENTS.md auto-loads on every `codex exec` (Codex's native behavior).

Start:

```bash
cd asst && ./start.sh             # claude flavor
cd my-agent && ./start.sh         # codex flavor
```

The agent runs in a detached `tmux` session named `claude-<name>` (claude flavor) or `codex-<name>` (codex flavor). DM the bot.

---

## First DM: asst introduces itself

On first contact, asst sends a one-shot orientation — how to talk to it, which natural-language phrases trigger built-in commands (compact, restart, switch model, status), how to spawn more agents — then deletes its own `FIRST_RUN.md` so it never greets you again.

---

## Spawning more agents

**Don't run `npx create-hermit-agent` a second time.** Tell asst:

> Create a new agent called `github-bot` with token `123:ABC...`. Purpose: triage my GitHub notifications.

asst's `provision-agent` skill scaffolds a sibling at `../github-bot/`, installs its plugin, starts it in a `claude-github-bot` tmux session, and replies with the new bot's `@handle`.

Agents are fully independent: separate bot tokens, separate memory, separate folders.

---

## Customize

Edit these in the agent folder:

| File | What to put there |
|---|---|
| `IDENTITY.md` | Name, vibe, one-line purpose |
| `USER.md` | You — pronouns, timezone, notes |
| `AGENTS.md` | `<!-- MISSION-START -->` block — this agent's mission |
| `TOOLS.md` | `<!-- AGENT-SPECIFIC-START -->` block — API keys, repo links, domain notes |

`SOUL.md` is baseline disposition — don't edit unless you want a different personality.

---

## Scheduled tasks

Just tell the agent what you want:

> Every 30 minutes, scan `memory/today.md` and flag urgent items.

asst's `cron` skill handles it. Tasks that must survive restarts go through the OS scheduler — `launchd` on macOS, `systemd --user` on Linux.

### macOS (launchd)

1. Drop a plist into your agent's `launchd/` folder — copy `launchd/cron-example.plist.tmpl`, set `Label` to `com.hermit-agent.<agent>.cron-<task>`, and point `ProgramArguments` at whatever you want run. Wrap the real work in `scripts/with-timeout.sh 1200` — 20 min is the ceiling, not a target. **Keep the template's `EnvironmentVariables` PATH block** — launchd's default PATH excludes `~/.local/bin` (where Claude Code installs `claude`), and tasks silently exit 127 after the next CLI upgrade without it.
2. **If the task invokes Claude**, use `scripts/claude-tmux-run.sh cron/<task>.md` rather than `claude -p`. Starting 2026-06-15 Anthropic splits Claude Max quota into Interactive + Agent SDK buckets — `claude -p` draws against the smaller Agent SDK bucket at API rates, while the tmux helper keeps the cron in the Interactive bucket alongside your normal sessions. See AGENTS.md → "Cron Safety" for the cost math. A starter prompt template lives at `cron/example-tmux.md`.
3. Sync to the live LaunchAgents dir: `./scripts/launchd-sync.sh .` (idempotent: `LOADED` new, `RELOAD` changed, skip unchanged; `--dry-run` to preview).
4. Confirm: `launchctl list | grep com.hermit-agent.<agent>`.

### Linux (systemd-user)

1. Drop a `.service` + `.timer` pair into your agent's `systemd/` folder — copy `systemd/cron-example.service` and `systemd/cron-example.timer`, edit `ExecStart` (point it at your script) and the `OnUnitActiveSec` cadence. Wrap the real work in `scripts/with-timeout.sh 1200`. **Keep the `Environment=PATH=…` line** — systemd-user's default PATH excludes `~/.local/bin` and `claude` won't resolve without it. Same Claude-invocation rule as macOS step 2: prefer `scripts/claude-tmux-run.sh` over `claude -p` for billing-bucket reasons (AGENTS.md → "Cron Safety").
2. Sync to `~/.config/systemd/user/`: `./scripts/systemd-sync.sh .` (idempotent: `INSTALL` new, `UPDATE` changed, skip unchanged; `--dry-run` to preview). The script `daemon-reload`s and `enable --now`s every timer it finds, and warns if lingering isn't enabled.
3. Confirm: `systemctl --user list-timers 'hermit-<agent>-*'`. Tail logs with `journalctl --user -u hermit-<agent>-<task>.service -f`.

Writing the unit files alone does NOT activate them — the sync script is the difference between "generated" and "running". Re-run it any time you add, edit, or rename a unit. And the timeout wrapper is there for a reason: a cron that drifted off-prompt once wedged for 12h38m and blocked three fire windows. `AGENTS.md` → "Cron Safety" documents the discipline.

---

## Master vs worker hermits

Each machine has exactly one **master** hermit and any number of **workers**:

- **Master** — the first hermit installed on the machine (typically named `asst`). It owns the multi-agent status digest LaunchAgent, hosts the `provision-agent` and `provision-clone` skills the user invokes from Telegram, and is the single coordinator that watches every other hermit's pid + state. Created by `npx create-hermit-agent <name>` when no other hermit exists on the box.

- **Worker** — every hermit created after the master, whether via `npx create-hermit-agent <name>` (fresh worker) or `npx create-hermit-agent --clone-of <parent>` (doppel of an existing hermit). Workers run their own Claude Code session and their own Telegram bot, but they do not install a status-reporter LaunchAgent and they do not provision other hermits — only the master does that.

The master/worker split is enforced by the CLI: if a `com.hermit-agent.*.status-reporter.plist` already exists on the machine, the installer skips registering another. So you can't accidentally create a second master, even if you forget the rule. Doppels (`--clone-of`) skip the LaunchAgent step entirely and are always workers.

The CLI prints which role each new hermit takes when it finishes scaffolding:

```
✓ Master hermit ready (this Mac's coordinator).      ← first install
✓ Worker hermit ready (master / coordinator: asst).  ← subsequent installs
✓ Doppel ready (worker hermit, master: asst).        ← --clone-of
```

To hand off mastership to a different hermit, see *Multi-agent status digest* below.

---

## Multi-agent status digest

The CLI automatically installs a `launchd` coordinator the first time you run it on a machine. Every 10 minutes it pushes a digest of all hermits on the box to the coordinator's Telegram chat: 🟢 idle · 🟨 running · 🟥 stuck · ⚫ down.

- One coordinator per machine. When `create-hermit-agent` detects an existing `com.hermit-agent.*.status-reporter.plist`, it skips — subsequent hermits don't stack their own jobs.
- The first agent you install (default `asst`) is the coordinator. Its plist lives at `~/Library/LaunchAgents/com.hermit-agent.asst.status-reporter.plist`.
- To disable: `launchctl unload ~/Library/LaunchAgents/com.hermit-agent.<coordinator>.status-reporter.plist`.
- To hand off to a different coordinator: unload the old plist, delete it, re-run `create-hermit-agent` from a new agent (or manually `cp launchd/status-reporter.plist ~/Library/LaunchAgents/com.hermit-agent.<new>.status-reporter.plist && launchctl load ...`).

### Claude Code usage block

Each digest also carries a 💰 section summarizing your Claude Code spend:

```
💰 claude code
5h: 18% (resets 7:20am)
week: 14% (resets May 3)
block: $25 · burn $25/h · proj $112 (3h29m left)
today: $145 / 227.5M tok
humanize $84 · d $31 · auramate-engineer $17
```

Three independent data sources, each fails silently:

- **5h + weekly quota %** — there's no `claude --status --json` flag, so `scripts/claude-quota-probe.sh` spawns a throwaway Claude Code REPL in `/tmp/_quota_probe`, drives `/status` → Usage tab via `tmux send-keys`, scrapes the rendered pane, and tears everything down. ~8s per probe; the JSONL transcript Claude Code creates has zero API calls and is deleted right after capture, so it never lands in `ccusage` totals.
- **Active 5h block burn rate + projection** — `npx ccusage blocks --active --json`, parsed for `costUSD`, `burnRate.costPerHour`, `projection.totalCost`, `projection.remainingMinutes`.
- **Today's per-project cost + tokens + top 3 spenders** — `npx ccusage daily --since <today> -i --json`, summed across all `~/.claude/projects/<encoded-cwd>/` transcripts.

Override the probed `claude` binary with `CLAUDE_BIN=/path/to/claude` in the LaunchAgent env if you have multiple installs. Skip the section entirely by removing or chmod-ing `claude-quota-probe.sh` to non-executable — the report falls back gracefully.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Agent doesn't reply | `tmux attach -t claude-<name>` to see live state. Also check `restart.log`, `claude-agent.log`. |
| Plugin subprocess missing | `./restart.sh` auto-retries once. Still broken? Check `~/.claude/channels/telegram-<name>/.env` is mode 600 with the token. |
| `exceeds the dimension limit` image crash | All image Reads MUST go through `scripts/safe-image.sh` first. Recover with restart + `/compact`. |
| `claude plugin install failed` | Ensure `claude` is on PATH and logged in (`claude login`). |
| Context bloat | Ask on Telegram — "compact" / "压缩上下文" / "精简一下" — the agent fires `/compact` via tmux. Or type `/compact` directly in the pane. |
| Bot silent on a fresh Mac | Claude Code may have raised the "trust this folder" or "allow dangerous mode" TUI dialog — which blocks startup. The CLI pre-acknowledges both, but if something went wrong, `tmux attach -t claude-<name>`, press Enter to dismiss any pending dialog, then detach with Ctrl-b d. |

---

## FAQ

**Do I need to pre-install the Telegram plugin in Claude Code?**  
No. `create-hermit-agent` runs `claude plugin install telegram@claude-plugins-official -s project` for every new agent. First install downloads to `~/.claude/plugins/cache/`; subsequent agents register against the cache per-project. Zero manual plugin setup.

**Linux / Windows support?**  
**Linux**: yes, with caveats. The CLI auto-detects the platform and ships a reduced surface for Linux v1 — no browser layer, no image-safety layer (both are macOS-shaped: sips, `.app` paths, Playwright integration tuned for Chrome on macOS). The CLI strips those scripts and the related `settings.json` / `settings.local.json` entries on Linux scaffolds so the agent dir doesn't carry dead files. Scheduling uses `systemd --user` instead of `launchd`. Telegram plugin, persona, memory, multi-agent status digest, and the `cron -p` Bot API push path all work the same.  
**Windows**: not supported. WSL2 might work (it's effectively Linux) but isn't tested.

**Can multiple agents share a bot token?**  
No. Telegram's Bot API routes each bot's updates to exactly one listener. Sharing causes message hijacking. Each agent needs its own `@BotFather`-issued token.

**Where's the bot token stored?**  
`~/.claude/channels/telegram-<name>/.env` (mode 600, outside the project). Also echoed into `.claude/settings.local.json` (gitignored).

**Does the first DM trigger a pairing code?**  
No. The CLI pre-populates `~/.claude/channels/telegram-<name>/access.json` with your user ID pre-allowlisted, so your own DMs pass through from message one. Strangers who find the bot's `@handle` still get the standard pairing challenge (`dmPolicy: "pairing"`), not silent delivery.

**How do I delete an agent cleanly?**

```bash
# macOS:
launchctl unload ~/Library/LaunchAgents/com.hermit-agent.<name>.*.plist 2>/dev/null
rm -f ~/Library/LaunchAgents/com.hermit-agent.<name>.*.plist

# Linux:
for u in ~/.config/systemd/user/hermit-<name>-*.{service,timer}; do
  [ -f "$u" ] && systemctl --user disable --now "$(basename "$u")"
done
rm -f ~/.config/systemd/user/hermit-<name>-*.{service,timer}
systemctl --user daemon-reload

# Both:
tmux kill-session -t claude-<name> 2>/dev/null
rm -rf <agent-folder>
rm -rf ~/.claude/channels/telegram-<name>
```

Also revoke the bot via `@BotFather` if you're done with it.

---

## License

[MIT](LICENSE).
