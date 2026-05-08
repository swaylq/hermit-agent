---
name: provision-clone
description: Spawn a doppel (clone, 复制体) of an existing hermit agent — same workspace files via symlinks, but its own Claude Code session and its own Telegram bot. Use when the user asks for a "clone", "doppel", "复制体", "fork agent", or "spin up another <existing-agent>".
user_invocable: true
---

# Provision a Doppel (Clone) of an Existing Hermit

A **doppel** shares the parent agent's workspace via symlinks (SOUL/USER/AGENTS/TOOLS/MEMORY + scripts/, browser/, node_modules/, etc.) but runs as its own Claude Code session, has its own bot, its own tmux pane. Use this when the user wants a parallel viewpoint on the same project — e.g., one humanize doppel for review, another for experimentation.

If the user wants a **brand-new agent** with its own workspace, use `provision-agent` (npx create-hermit-agent without `--clone-of`) instead.

## Host inheritance

Cloning preserves the parent's host. If you (the running agent) are claude-flavored, your doppel is claude-flavored. If parent is codex-flavored, the clone is codex-flavored. The CLI infers host from the parent's directory structure — there is no `--host` flag in clone mode.

**Codex-flavored clones are not yet supported by `--clone-of`** (the symlink-based clone pattern is built around Claude Code's `.claude/` layout). If a codex-hermit user asks for a doppel, run a fresh `provision-agent --host codex` instead and tell them it's a fresh hermit, not a clone.

**Master vs worker rule.** Doppels are always **workers** — never masters. The master of this machine is the first hermit installed (typically `asst`), which owns the status-reporter LaunchAgent. The CLI's `--clone-of` mode skips that LaunchAgent entirely, so you can't accidentally spawn a second master via this skill. A worker can be a clone of the master, of another worker, or of another doppel's parent — the relationship that matters is workspace inheritance, not master/worker hierarchy.

## Concept

```
~/hermits/asst/                            parent agent
~/hermits/asst-doppel-1/                   clone (sibling)
  SOUL.md, USER.md, AGENTS.md, TOOLS.md   → symlink to ../asst/
  MEMORY.md (read-shared, write-careful)  → symlink
  CLAUDE.md (bootstrap order)             → symlink
  memory/, scripts/, browser/, node_modules/, .claude/skills/  → symlink
  IDENTITY.md       (real, "I'm asst-doppel-1")
  BOOTSTRAP.md      (real, MEMORY.md write discipline)
  HEARTBEAT.md      (real, doppel's own task list)
  .claude/          (real, per-clone settings + state)
  restart.sh        (real, knows its own tmux session name)

tmux session: claude-asst-doppel-1
telegram:     new bot, new ~/.claude/channels/telegram-asst-doppel-1/
DM routing:   only to the doppel; parent has no awareness
daily log:    memory/YYYY-MM-DD-doppel-1.md (suffixed, no collision with parent's)
```

## Arguments to collect

Before invoking the CLI, you need from the user (ask via Telegram if missing):

1. **Parent name** — name of the existing hermit to clone (e.g., `asst`). Must exist as a sibling of your current working directory (or as an absolute path). If the user didn't name a parent, list candidates first (see "Listing candidates" below) and ask.
2. **Bot token** — new Telegram bot token from @BotFather. Each doppel needs its own; do NOT reuse the parent's token. The CLI validates the token against `getMe` before scaffolding.

The **clone number** (`doppel-1`, `doppel-2`, …) is auto-computed by the CLI as `max(existing) + 1`. Do not ask the user.

The **chat ID** defaults to the parent's `TELEGRAM_CHAT_ID` (read from `../<parent>/.claude/settings.local.json`). Only ask the user if they want a different chat to receive the doppel's messages.

## Listing candidates

If the user didn't name a parent, list cloneable hermits — anything sibling to cwd that has a CLAUDE.md and isn't itself a doppel:

```bash
for d in ../*/; do
  name=$(basename "$d")
  case "$name" in
    *-doppel-*) continue ;;     # don't clone clones
  esac
  [ -f "$d/CLAUDE.md" ] || continue
  echo "$name"
done
```

Reply with the list and ask which to clone.

## Phases

### Phase 1 — bootstrap (15–20s)

Single `npx create-hermit-agent --clone-of <parent>` invocation does it all: resolves parent path, computes the next doppel-N, creates the clone dir, writes the symlinks for shared files, writes the per-clone real files (IDENTITY.md / BOOTSTRAP.md / HEARTBEAT.md / .claude/), writes the STATE_DIR with the new bot token, validates the token via Telegram, installs the telegram plugin at project scope.

```bash
npx create-hermit-agent --clone-of <parent> \
  --bot-token <token> \
  --yes
```

`--yes` skips the interactive prompts since you have what's needed. The CLI will pull `--user-id` from the parent's settings.local.json automatically; pass `--user-id <chat-id>` only if you want a different chat.

The CLI:
1. Validates `<parent>` exists with a CLAUDE.md.
2. Computes next doppel slot (`<parent>-doppel-N` where N = max + 1).
3. Validates the bot token against Telegram's `getMe`.
4. Creates the clone dir as a sibling of the parent.
5. Symlinks shared files: CLAUDE/SOUL/USER/AGENTS/TOOLS/MEMORY (+ ACCOUNTS/FIRST_RUN if present), `memory/`, `scripts/`, `browser/`, `node_modules/`, `projects/`, `.claude/skills/`.
6. Writes per-clone real files: IDENTITY.md (clone identity), BOOTSTRAP.md (write discipline), HEARTBEAT.md (empty), .claude/settings.json + settings.local.json (per-clone token + STATE_DIR + hooks pointing to the clone's own scripts/), restart.sh.
7. Writes STATE_DIR (`~/.claude/channels/telegram-<clone-name>/`) with `.env` (mode 600) + access.json pre-allowing the user.
8. Runs `claude plugin install telegram@claude-plugins-official -s project` from the clone's dir.
9. Pre-acks Claude's first-run trust dialogs for the new project path.
10. Skips the LaunchAgent status-reporter install (the parent's coordinator is enough) and skips `npm install` (node_modules is symlinked).

### Phase 2 — launch (~5–8s)

Doppels use the same restart pattern as fresh agents — empty `OLD_PID`:

```bash
<parent>-doppel-<N>/restart.sh "" &
```

Then poll the tmux pane until "Listening for channel messages" appears:

```bash
for i in $(seq 1 20); do
  sleep 1
  tmux capture-pane -t claude-<parent>-doppel-<N> -p 2>/dev/null | grep -q "Listening for channel" && break
done
cat <parent>-doppel-<N>/agent.pid  # verify PID written
```

Hard-fail if not ready in 20s.

### Phase 3 — verify + reply

Confirm the process is alive and reply to the user via your own bot (not the new doppel's):

```bash
kill -0 $(cat <parent>-doppel-<N>/agent.pid) && echo alive || echo dead
```

Reply with:
- Clone name + sibling path
- Parent agent name
- New bot @username (so the user knows which bot to DM)
- Reminder: "DM @<newbot> to wake them — parent is unaware of this conversation"

## Hard rules — don't do these

- **Don't clone a clone.** If the user picks a parent that's itself a doppel (`*-doppel-*`), refuse. Tell them to clone the original instead — the symlink chain breaks N-numbering.
- **Don't reuse a bot token.** Each doppel needs its own from @BotFather. Reuse means the second doppel hijacks the first's updates.
- **Don't pre-populate the doppel's MEMORY.md.** It's symlinked from the parent — there's nothing to populate. The clone reads the parent's long-term memory and writes (carefully) per BOOTSTRAP.md discipline.
- **Don't customize IDENTITY.md beyond what the CLI writes.** Default identity already explains the doppel relationship. If the user wants a distinct vibe, they edit it themselves.
- **Don't try to "merge" doppel changes back to parent.** The workspace is shared — there's nothing to merge. Both write the same files; the discipline in BOOTSTRAP.md handles collisions.

## Management Commands

### Stop a doppel
```bash
kill $(cat <parent>-doppel-<N>/agent.pid)
# or
tmux kill-session -t claude-<parent>-doppel-<N>
```

### Check if a doppel is running
```bash
kill -0 $(cat <parent>-doppel-<N>/agent.pid) 2>/dev/null && echo running || echo stopped
```

### List a parent's doppels
```bash
for d in ../<parent>-doppel-*/; do
  name=$(basename "$d")
  [ -f "$d/agent.pid" ] || { echo "$name: never started"; continue; }
  pid=$(cat "$d/agent.pid")
  kill -0 "$pid" 2>/dev/null && echo "$name: running ($pid)" || echo "$name: stopped"
done
```

### Delete a doppel cleanly
```bash
NAME=<clone-name>
PID=$(cat ../$NAME/agent.pid 2>/dev/null)
[ -n "$PID" ] && kill "$PID" 2>/dev/null
tmux kill-session -t "claude-$NAME" 2>/dev/null
rm -rf ../$NAME                                      # safe — only removes symlinks + real per-clone files
rm -rf ~/.claude/channels/telegram-$NAME
# also revoke the bot token in @BotFather if you want to retire it
```

The `rm -rf` is safe because the workspace files are symlinks — removing a symlink doesn't touch the target. The only real files in the clone dir are IDENTITY.md, BOOTSTRAP.md (likely already deleted post-first-turn), HEARTBEAT.md, .claude/, restart.sh, and runtime state. If you ever turn a clone into a "fork" by replacing symlinks with real copies, **stop and verify before `rm -rf`** — symlink replacement changes the safety calculus.

## Notes

- The status reporter (`scripts/multi-agent-status-report.sh`) auto-discovers doppels because each has a CLAUDE.md (symlinked) and `.claude/state/session-status.json` (per-clone real). Doppels show up as separate rows in the digest.
- `ccusage` / claude-quota-probe see doppel sessions correctly because each session has its own encoded-cwd project dir under `~/.claude/projects/`. Top-spender list shows doppels as separate entries.
- The `claude plugin install` step modifies `~/.claude/plugins/installed_plugins.json`. Same path the fresh-agent flow uses; not a `claude mcp` call, so it doesn't break running sessions' MCP handles.
- If the parent has `FIRST_RUN.md`, it gets symlinked too. The clone reads it on first start (because AGENTS.md says to), follows it, then deletes the link — but since it's a symlink, deleting the link doesn't touch the parent's FIRST_RUN.md. (If parent's was already gone, no symlink is created.)
