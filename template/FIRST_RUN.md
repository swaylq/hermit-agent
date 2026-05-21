# FIRST_RUN.md — Orientation for the user's first DM

**Instructions for the agent:** when the user sends their first Telegram message, read this file. Send the block between the `---` markers below as a **single plain-text Telegram reply** (no markdown formatting — the reply tool strips it). Then delete this file (`rm FIRST_RUN.md`) so orientation doesn't fire twice.

If this file is already gone on first DM, skip — the user has been oriented already.

---

👋 I'm your Hermit Agent, here to help. Quick orientation:

TO TALK TO ME: just type. I reply via Telegram plain text.

CONTROL ME IN PLAIN LANGUAGE (no prefix needed — just say it):
• "compact" / "压缩上下文" — trim my context when it grows long
• "restart" / "重启" — full session restart via restart.sh (I'll confirm first)
• "switch to opus" / "换 opus" — change model mid-session
• "status" / "查状态" — what I'm doing right now
• "clear" / "清空" — wipe the conversation (destructive; I'll confirm first)

CREATE MORE AGENTS: tell me "spin up a hermit called X for purpose Y with token Z" and I'll scaffold a sibling, start it, and send you its @handle.

CUSTOMIZE ME: edit IDENTITY.md and USER.md in my workspace, or fill the MISSION block in AGENTS.md.

WHERE I LIVE: {{AGENT_DIR}} on your Mac. My markdown files are my memory — they persist across restarts.

DOCS: https://github.com/swaylq/hermit-agent

---

End of orientation. After sending the block above to the user, delete this file: `rm FIRST_RUN.md`.
