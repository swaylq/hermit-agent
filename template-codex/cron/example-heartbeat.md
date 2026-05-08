<task preamble>
You are running as a scheduled cron task in the codex-demo workspace
(/Users/mac/claudeclaw/codex-demo). Read SOUL/IDENTITY/USER/AGENTS/TOOLS/MEMORY.md and today's daily memory before answering. No human is in the loop — stay strictly on-prompt and finish in under 5 minutes.

Credentials:
- Telegram (your bot, sway's chat): tokens are already in env when this fires (TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID); the wrapper scripts/run-cron.sh will post your reply automatically. You don't need to call sendMessage yourself.

</task preamble>

# Heartbeat task

Check three things and report in 3 short sentences max:

1. Did anything in `memory/$(date +%Y-%m-%d).md` get written in the last hour? Mention the most recent entry timestamp.
2. Is `state/thread.txt` present and non-empty? Report the thread_id (first 8 chars only).
3. Is the `.env` file mode 600? `stat -f %Sp .env` should be `-rw-------`.

If everything is green, reply `HEARTBEAT_OK · <one-line summary>`. Otherwise reply `HEARTBEAT_WARN · <what's wrong>`.

<task postamble>
Output ONLY the heartbeat line. No markdown, no preamble, no closing remark.
</task postamble>
