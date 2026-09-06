# AGENTS.md — Your Workspace

This folder is home. Treat it that way.

## Every Session

Bootstrap order lives in `CLAUDE.md`. Two rules for every session:

- **Main session only** (direct chat with the user): load `MEMORY.md`. In shared/group contexts, skip it — it contains personal context.
- **Write it down, no "mental notes".** "Remember this" → append to `memory/YYYY-MM-DD.md` or the relevant file. Lessons → update this file or `TOOLS.md`. Text > Brain.

### Startup Greeting

When the user sends their first message:

1. **If `FIRST_RUN.md` exists at the workspace root** — read it. Send the block between the `---` markers as a single plain-text Telegram reply (no markdown formatting). Then delete `FIRST_RUN.md` with `rm FIRST_RUN.md` so orientation doesn't fire again. This is the first-use onboarding for a freshly-bootstrapped hermit.
2. **If `FIRST_RUN.md` is already gone** — just reply with a brief greeting confirming you're online. Keep it concise; don't list files you read.

(Note: Claude Code sessions are passive — you can't proactively send before the user speaks.)

## Memory

Two tiers:

- `memory/YYYY-MM-DD.md` — raw daily log (append-only; one file per day)
- `MEMORY.md` — curated long-term (main session only; security boundary)

### Search before you answer — HARD RULE

Retrospective questions ("earlier / last time / do you remember…") — BEFORE answering:

1. `grep -r <keyword> memory/`
2. If the auto-memory system is enabled for this project, also grep there

No search = guessing. Going off memory alone has been a source of bad answers.

### Dual-write — important events → curated memory too

Daily logs are opaque to semantic search. When writing a daily-log entry for any of these, ALSO create a curated memory entry in `MEMORY.md` (pointer-style, link to a dedicated file if needed):

- Important decisions / architecture changes
- New user feedback or stated preferences
- Root-cause conclusions from debugging
- New agent creation / infrastructure changes

Prefer fewer, well-described curated entries over a flood. Evict/prune when a memory stops being load-bearing.

## Image Safety — HARD RULE

An image with long edge > 2000px crashes the session mid-turn — every API call afterwards returns 400 "Could not process image" until `/compact` or restart, including the reply tool, so you go dark with no way to notify. Defense is **layered**:

**Layer 1 — mechanical (PreToolUse hook, always on):** `scripts/hooks/pre-read-image.sh` is wired into `.claude/settings.local.json` to fire before every `Read`. It parses the tool input, skips non-images fast (~9ms), runs `sips` on images, and for anything over 2000px it calls `scripts/safe-image.sh` to create a resized sidecar then blocks the Read with stderr telling the model to Read the sidecar instead. If `sips` can't parse the file at all, the hook blocks outright — fail-closed, because a wedged session is worse than a blocked Read.

**Layer 2 — the rule:** if the hook is ever disabled, misfires, or you're Reading outside the hook's coverage, still run `scripts/safe-image.sh <path>` yourself before Reading any png/jpg/jpeg/gif/webp/bmp/tiff — including Telegram downloads (`download_attachment`), playwright screenshots, user-sent photos. **If `safe-image.sh` exits non-zero, STOP — do NOT Read the original as fallback.** A failed resize means `sips` can't parse the image (corrupt, zero bytes, unsupported format, `<nil>` dimensions); Reading the original wedges the session.

Past incident (2026-04-23): an agent took 7 playwright screenshots at 2880x2400 (default full-page capture) and Read them without `safe-image.sh` — session wedged for 10 minutes, blocked inbound Telegram messages from a collaborator. The hook exists to make that mistake impossible.

## MCP Registry Safety — HARD RULE

**Never run `claude mcp add` or `claude mcp remove` inside a live session when you depend on other MCP tools** (especially `mcp__plugin_telegram_telegram__reply` — losing that = silent agent with no way to notify).

Mutating the MCP registry mid-session invalidates EVERY deferred MCP tool schema in the session — not just the one being added/removed. Telegram reply, playwright-browser, everything. They all go "no longer available" until the session restarts.

If you must add/remove:
1. **Preferred:** stop the agent → `claude mcp add|remove …` → `./start.sh` (or `./restart.sh <old_pid>`).
2. **Acceptable:** run the mutation, then immediately fire `./restart.sh $(cat agent.pid)` via Bash. Current turn finishes, tmux respawns the pane with a fresh claude.
3. Write "Session restart required" to memory BEFORE touching the registry in case anything fails mid-flight.

**Bot-API-direct scripts are NOT a substitute for MCP Telegram in interactive sessions.** In the tmux-based main session (user-facing, plugin sync runs normally), if MCP Telegram breaks you restart — you do not route around it by having some `tg-send.sh` hit `https://api.telegram.org/bot.../sendMessage`. Bot API curl can one-way push plain text but has NO inbound delivery, NO `reply_to`, NO reactions, NO attachments. Writing one is papering over a broken session. The fix is restart. See 2026-04-23: a sibling agent (`sway003/design`) ran `claude mcp add TalkToFigma …` mid-session, killed all MCP handles, wrote a Bot API fallback, went dark for hours. Should have restarted.

**Cron -p exception.** Non-interactive `claude --dangerously-skip-permissions -p` invocations (launchd-fired cron tasks) by design don't run plugin sync — tested, neither `--mcp-config` nor `--plugin-dir` can bring the telegram plugin's bun online for the duration of a `-p` run, and `mcp__plugin_telegram_telegram__*` tools never appear in deferred-tools. For those sessions, curl-to-Bot-API for the final report is **permitted**; it isn't a workaround, it's the platform constraint. Distinction: if you're in a tmux session where MCP should work and you're routing around it, that's "restart." If you're in a cron `-p` where MCP never loaded, that's "curl."

## Shell Safety — HARD RULE

**Never point ANY recursive search at a wide root.** On macOS this includes the shell `find` command, the built-in **Glob tool**, and the built-in **Grep tool** — Glob and Grep lean on `ripgrep` under the hood, so "I'm using the Claude tool, not find" does NOT save you. A pattern anchored at `/Users/<you>/**` or `~/**` can reach `~/Library/Containers` (app sandboxes, 100k+ files) and deadlock Claude Code's Node event loop the same way `find /` does.

Three documented incidents:

- **`find /` (Bash)** — `find / -iname "*foo*" | head -10`. macOS `/System` `/Library` `/private` contain millions of files. The `find` ran 9 min without returning. External `kill` on the find PID left the parent shell as a defunct zombie that the Claude Code main process never reaped. The Node event loop blocked sleeping on the shell pipe — `ESC`/`Ctrl-C`/`SIGCHLD` all stopped reaching the UI. Recovery: `kill -9` the claude main process + `restart.sh`.

- **`find /Users/<you> -maxdepth 5` (Bash, in cron)** — `find /Users/mac -maxdepth 5 -type f \( -name "*.json" -o -name ".env*" … \) | xargs grep -l TELEGRAM_BOT_TOKEN | head -5`. Crawled `~/Library/Containers` for 12h38m without completing. `-maxdepth 5` does nothing against sandbox tree depth.

- **Glob tool `/Users/<you>/**/…`** — a session called the Glob tool with a pattern anchored at `/Users/mac/**/sim/package.json`. The tool's internal 20s ripgrep timeout fired, but the timeout didn't cleanly propagate — Node event loop hung 20+ min, session dark until `kill -9` + `restart.sh`. The lesson: **"use Glob/Grep instead of find" is NOT a fix if the pattern has a wide root.** The tools share the vulnerability.

Rules:

1. **Never `find /`. Never `find /Users/<you>`. Never `find ~`.** And **never point the Glob tool or Grep tool at `/Users/<you>/**` or `~/**`** — same ripgrep, same wedge. `~/Library` is a bottomless pit (Containers, Caches, Group Containers, WebKit) and no `-maxdepth` saves you.
2. Every `find` pins a narrow root AND uses `-maxdepth 3` by default. Raise only for a specific reason that justifies the risk.
3. Glob / Grep tool `path` or `pattern` must begin with a specific subdirectory — e.g. `<agent-dir>/memory/**/*.md`, `<agent-dir>/skills/**/SKILL.md`. Not `/Users/<you>/**` or `~/**`.
4. File-by-name queries: `mdfind -onlyin <dir> <query>` — Spotlight index, seconds, doesn't recurse at all.
5. Never pipe `find | xargs grep` on a wide root. Even with `head -N` at the tail, grep won't short-circuit until find produces enough matches, which may never arrive.
6. Any recursive search — Bash, Glob, or Grep — running > 60s with no sign of progress: KILL and rethink. Don't hope.
7. Once wedged, external kill of the child isn't enough — `kill -9` the claude main process + `restart.sh`.

## Token Safety — HARD RULE

Credentials live at well-known paths documented in `TOOLS.md` (Keychain-backed tokens, mode-600 secrets files, settings env blocks). Reference them by path; never crawl the filesystem for them.

Rules:
1. **Never grep or find the filesystem for tokens, API keys, secrets, `TELEGRAM_BOT_TOKEN`, `.env*`, `api_key`, `ghp_`, `sk-`, `Bearer`.** If you don't know where a credential lives, check `TOOLS.md` or ask the user. Crawling wastes time, hits `~/Library` traps, and any match ends up in logs.
2. **Never echo / print / log a token value.** Not to stdout, not to daily memory files, not to Telegram, not to cron logs. To prove a credential works, run the command that uses it and report the HTTP status / response metadata — never the token itself.
3. **Never pass a token on the command line.** `curl -H "Authorization: Bearer $TOKEN"` exposes it in `ps auxwww`. Use `--header @file`, stdin, or an env var the callee already has access to.
4. **Never commit credentials.** The `.gitignore` ships with `.env*` and secrets paths. Before any `git add`, spot-check the diff.
5. **Historical leaks** (dead tokens in old archives) get redacted in place: `[REDACTED YYYY-MM-DD — <why>]`. Don't wait for rotation.

## Cron Safety — HARD RULE

Cron tasks run as `claude -p` with the prompt from `cron/<task>.md`. The scheduling layer is platform-conditional — macOS uses LaunchAgent plists under `launchd/com.hermit-agent.<agent>.cron-*.plist` (synced via `scripts/launchd-sync.sh`); Linux uses systemd-user units under `systemd/<task>.{service,timer}` installed as `hermit-<agent>-<task>` in `~/.config/systemd/user/` (synced via `scripts/systemd-sync.sh`, tail logs with `journalctl --user -u hermit-<agent>-<task>.service`). Two rules for anything that fires inside a cron invocation:

1. **Stay strictly on-prompt.** If `cron/moltbook-outreach.md` says do moltbook outreach, you do moltbook outreach — not "let me also audit X" or any ad-hoc cleanup that occurs mid-task. Cron has no human in the loop and cannot be interrupted by Telegram. Off-prompt exploration is how a cron burns half a day on the wrong thing.
2. **Hard runtime ceiling.** Wrap every cron in `scripts/with-timeout.sh 1200` (provided). Twenty minutes is the ceiling — not a target. If a task legitimately needs more than that, reshape it: split into multiple crons, preprocess outside the invocation, persist state between runs. Don't raise the timeout.
3. **Default to `scripts/claude-tmux-run.sh`, not `claude -p`.** Starting **2026-06-15** Anthropic splits Claude Max quota into two buckets: an *Interactive* bucket (Claude.ai chat + Claude Code in terminal/IDE/Cowork — large, what you're used to) and an *Agent SDK* bucket (anything via `claude -p`, the SDK, or GH Actions — $20/mo Pro / $100/mo Max-5x / $200/mo Max-20x, overage at full API rates: Sonnet 4.6 $3/M in $15/M out). A 10-agent fleet with one heavy daily-distill cron easily blows past $200/mo of SDK bucket — but the same workload routed through the Interactive bucket (via `claude-tmux-run.sh`'s ephemeral tmux pattern) absorbs cleanly against Max-20x's existing cap. Use the helper for any cron that calls `claude`; reserve `claude -p` for cases where the Interactive bucket genuinely shouldn't apply (e.g., a CI workflow billed to a separate org).
4. **Legacy `claude -p` flags (only if you can't avoid `-p`).** Pass `--no-session-persistence` so the post-task JSONL flush doesn't drag past the timeout — a substantial outreach turn produces hundreds of KB of session-log writes during exit, and that disk flush has been observed to hang `claude -p` past 1200s even after the prompt's work was already complete (Telegram report sent). Do **not** pass `--bare` on agents authenticated through Claude Max OAuth (the macOS Keychain path): `--bare` skips keychain reads and demands `ANTHROPIC_API_KEY`/`apiKeyHelper`, so an OAuth agent fires once and fails with `Not logged in · Please run /login`. `claude-tmux-run.sh` sidesteps both gotchas — it launches `claude` interactively, no `-p` flush, no `--bare` auth detour.

A past cron drifted into `find ~/Library -type f -name "*.json" | xargs grep TELEGRAM_BOT_TOKEN` mid-run; it ran for 12h38m and blocked 3 fire windows before being killed manually. The with-timeout wrapper is the floor; discipline above it is on you.

## Subagents — HARD RULE

Only for a wide sweep whose middle output you throw away — many files searched, one
conclusion back. Not for what fits in a couple of tool calls, not when you need the full
output, never one inside another — a PreToolUse hook
(`scripts/hook-block-nested-subagent.sh`) blocks that last one. And not as your next move
after something failed: a detour that just ate your time is exactly when handing the work
off feels right and is worst. Retry differently yourself.

## Group Chats

In a Telegram group, you're a participant — not the user's voice or proxy. Think before you speak. Default to silence unless directly addressed or clearly contributing.

- Direct @mention or reply → respond.
- Question aimed at the group, you know the answer → respond concisely.
- Chatter, jokes, off-topic → stay silent. You're a guest.
- Emoji react to acknowledge without speaking.

## Telegram Replies — Hard Rules

When a message arrives via `<channel source="plugin:telegram:telegram">`, the user is reading Telegram, not your transcript. Three rules to internalize:

1. **Deliverables go through the reply tool, not transcript text.** Anything the user should actually see — summaries, reports, results, confirmations — must go via `mcp__plugin_telegram_telegram__reply` (or `edit_message` for in-progress updates). Transcript text is invisible to them. Quick internal scratch stays in transcript; the *deliverable* cannot.

2. **No markdown formatting in reply text.** The reply tool sends plain text. `**bold**`, `_italic_`, `# headers` show up as literal asterisks/hashes. For emphasis use ALLCAPS, 「」, or line-break structure.

3. **Never call AskUserQuestion.** Claude Code's built-in `AskUserQuestion` tool renders a TUI modal to the local tmux pane only — the user is on Telegram and never sees it, so the turn hangs forever waiting on stdin. To pose a choice, send a Telegram reply with numbered options (`1. ...\n2. ...`) and end the turn — the user answers in the next inbound message. A PreToolUse hook (`scripts/hook-block-askuserquestion.sh`) blocks the call defensively and tells the model to retry via reply, but don't reach for it in the first place.

These are silent failure modes — forgetting any one makes the user think you went dark.

## CLI Commands via Natural Language

sway triggers Claude Code built-in slash commands — and full session restart — through plain English or Chinese requests. No explicit sigil (the old `!!` prefix was retired 2026-04-23). Recognize the intent, then route through `scripts/exec-cli-command.sh "/<command>" <delay-seconds>` for CLI commands (schedules `tmux send-keys` with default 5s delay so the current turn finishes cleanly), or `./restart.sh $(cat agent.pid) &` via Bash for full restart.

Safe → invoke directly, then reply confirming what was scheduled:

- "压缩上下文" / "compact" / "compact the context" / "精简一下" / "太长了，整理一下" → `/compact`
- "换 opus/sonnet/haiku" / "切模型 opus" → `/model opus` (always pass the model as arg; bare `/model` opens a picker and is blocked)
- "查状态" / "show status" → `/status`

Destructive → confirm once via Telegram reply, unless the user already said "立即" / "force" / "confirmed" / "yes":

- "清空上下文" / "清空" / "clear context" / "reset" / "start fresh" / "重置对话" → `/clear`
- "退出" / "exit" / "logout" → `/exit` or `/logout`
- "重启" / "restart" / "重新启动" / "reboot" → NOT a CLI slash command; run `./restart.sh $(cat agent.pid) &` via Bash tool. `restart.sh` sleeps 3s, kills the old PID, and tmux respawns a fresh claude — loses current turn state but recovers from wedges (MCP registry changes, stuck tool calls, etc.)

Interactive commands are BLOCKED by `exec-cli-command.sh` (exit 4) — these open modal panels that freeze the REPL until dismissed at the terminal, cutting off Telegram replies. If asked for one, explain it's interactive-only and suggest running it at the terminal directly:

- `/help /config /memory /agents /mcp /permissions /bashes /hooks /ide`
- `/login /resume /bug /output-style /statusline /terminal-setup /vim`
- `/model` with NO arg (picker UI)

Reply pattern after invoking: "Scheduled /compact — new turn will start from compacted context in ~5s." For restart: "OK, restarting — back online in ~5s." Don't silently fire.

## Reporting Style — HARD RULE

**散文用中文**：完成 / 修复 / 合并 / 回滚 / 实测 / 发布 / 改动
**保留英文**：标识符（文件/函数/库名 / CLI 参数 / 哈希）、通用缩写（LLM / API / MCP / TDD）
**自创缩写首次展开**：`P1（最高优先级）`、`pp（百分点）`、`HC3（HumanCheck v3）`
**取消 ASCII 分隔**（=====），空行分段
**视觉分层**：标识符用反引号 `like_this`，散文留给中文动词

反例：`install.py:diff_summary — 现在递归 walk 所有 subdir, nested cli/ 改动不再被判 IDENTICAL`
正例：`install.py:diff_summary：递归扫描所有子目录，cli/ 嵌套改动不再被判定为 IDENTICAL`

## Heartbeats

If you set up a heartbeat cron, default prompt:

> Read HEARTBEAT.md if it exists. Follow it strictly. Don't infer or repeat old tasks. If nothing needs attention, reply HEARTBEAT_OK.

- **Reach out** when: important event arrived / calendar <2h / interesting find / >8h since any message.
- **Stay quiet** (HEARTBEAT_OK) when: late night 23:00–08:00 / user busy / nothing new since last check.
- **Proactive** (no permission needed): read/organize memory, `git status` checks, update docs, curate MEMORY.md.
- **Memory maintenance**: every few days skim recent `memory/YYYY-MM-DD.md`, distill into MEMORY.md, drop outdated entries.

## Hibernation (fleet feature)

If multiple hermits live on this machine, the **master/coordinator** also runs an idle-hibernator and a wake-poller (auto-installed at scaffold time). Workers don't run these — only the master does the fleet-wide sweep. With a single hermit, both LaunchAgents/timers still run but no-op cheaply (idle-hibernator skips self via `HIBERNATOR_SELF`; wake-poller's fast path exits in <100ms when no `paused.json` exists anywhere).

States are mutually exclusive:

- `agent.pid` present, `paused.json` absent → **alive**
- `agent.pid` absent, `paused.json` present → **hibernated** (`💤` in status digest)
- both absent → **down** (`⚫` in status digest)

Manual ops:

- Sleep an agent: `scripts/hibernate-agent.sh <name>` — saves session_id + remain-on-exit + kills claude/bun/chrome
- Wake an agent: `scripts/wake-agent.sh <name>` — respawns tmux pane with `claude --resume`, auto-picks "Resume from summary" for old/large sessions
- Tail what the schedulers did: `tail -f .claude/state/{idle-hibernator,wake-poller}.log`

The default idle threshold is **48h**; override with `IDLE_THRESHOLD_SEC=<seconds>` in the plist's `EnvironmentVariables`. Wake is triggered by any pending Telegram update to the hibernated agent's bot — the wake-poller checks every 60s, ACKs nothing (the freshly-respawned bun drains the queue with its own offset).

## Dead-session reaper (fleet feature)

The master also runs `scripts/reap-dead-sessions.sh` daily at 04:10 (LaunchAgent on macOS, systemd timer on Linux). Each Claude Code session writes a JSONL under `~/.claude/projects/<encoded-AGENTS_ROOT>-<agent>/`, and they accumulate fast — the reaper trims them once they're no longer needed.

A session is reaped only when ALL three hold:

1. `session_id` ≠ `<agent>/.claude/state/session-status.json` `.session_id` (active)
2. `session_id` ≠ `<agent>/.claude/state/paused.json` `.session_id` (hibernated wake target)
3. JSONL `mtime` older than `REAP_AGE_DAYS` (default 3 — buffer for manual `claude --resume`)

Files go to the OS recycle bin (`/usr/bin/trash` on macOS, `gio trash` on Linux), so recovery is one drag away — never `rm`. Companion subdir at `<proj>/<sid>/` is reaped together.

Manual ops:

- Preview without touching anything: `scripts/reap-dead-sessions.sh --dry-run`
- Wider buffer: `scripts/reap-dead-sessions.sh --age-days 14`
- Tail history: `tail -f .claude/state/reap-dead-sessions.log`

If `trash` / `gio` is missing the script refuses to run rather than `mv`-shuffle silently. Install with `brew install trash` (macOS) or your distro's GLib package (Linux).

---

<!-- MISSION-START -->
## Mission

_(One or two paragraphs describing this agent's specific focus. Customize to the persona. Example: "You handle personal messages and calendar triage. Bias toward terseness. Skip greeting ceremony — the user writes in shorthand, you write in shorthand too.")_
<!-- MISSION-END -->
