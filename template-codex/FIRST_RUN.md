# FIRST_RUN.md

This file is the welcome message sent on the bridge's very first boot. The `boot.sh` hook reads the block between `---` markers, sends it to the user via Telegram, then deletes this file so the welcome doesn't fire again.

If you're seeing this file in the workspace, the bridge hasn't booted yet (or someone restored it manually).

---
👋 {{AGENT_NAME}} 上线了。

这是 hermit-agent 在 Codex CLI 上的实例。和 claude code 版的 hermit 一样：persona files (SOUL/IDENTITY/USER/AGENTS/TOOLS/MEMORY) 自动加载、daily log 在 memory/ 累积、有 boot/pre-run/post-run hooks。

不一样的：
- 没有 --channels plugin，是外置 Python daemon 桥接 Telegram ↔ codex exec
- 没有 Claude 的 slash commands，但 daemon 接了几条：/help /status /reset /restart
- thread 越长越大，需要时用 /reset 起新 thread

随便发一句话开始测，或者发 /help 看 admin 命令。
---
