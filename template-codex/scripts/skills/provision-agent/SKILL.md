---
name: provision-agent
description: Bootstrap a new codex-flavored hermit agent (placeholder).
trigger: "新建 agent" / "provision" / "spawn agent" / "再开一个 codex hermit"
---

# provision-agent skill (placeholder)

This is a stub. Eventually the official hermit-agent template (`npx create-hermit-agent`) will accept `--host codex` and bootstrap a workspace with the same persona files + Telegram daemon + hooks layout you see here.

## What "provisioning" means

Spawn a sibling codex hermit at `<parent>/<name>` that has:
- its own persona files (SOUL/IDENTITY/USER/AGENTS/TOOLS/MEMORY)
- its own Telegram bot (user must create via @BotFather and supply token)
- its own `.env` (mode 600), `state/`, `memory/`
- its own `tg-bridge.py` (linked or copied from a shared location)
- its own tmux session (`codex-<name>`) and optional launchd plist
- distinct codex thread persistence (don't share `~/.codex/sessions/` cross-agent — each agent has its own thread.txt pointing into the shared session store, but the threads are independent)

## Manual steps until the template flag lands

1. `cp -R /Users/mac/claudeclaw/codex-demo /Users/mac/claudeclaw/<new-name>`
2. Edit `IDENTITY.md` / `USER.md` / `MEMORY.md` for the new persona
3. Wipe `state/` and `memory/`, regenerate `.env` with new bot token (keep `TELEGRAM_CHAT_ID`)
4. Update tmux session name in `start.sh` and `restart.sh`
5. Update launchd plist `Label` and paths if you want cron
6. Run `./start.sh`

This SKILL.md will be replaced with a real implementation once the template flag lands.
