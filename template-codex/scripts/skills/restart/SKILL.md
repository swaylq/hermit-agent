---
name: restart
description: Restart the bridge daemon. State (thread.txt, update_id.txt) is preserved.
trigger: 重启 / restart / reboot / "重新启动"
---

# restart skill

Kills the current `codex-demo` tmux session and respawns it via `start.sh`. Intended for use when:

- daemon is wedged or unresponsive
- you've edited `tg-bridge.py` or hooks and need them reloaded
- you want a clean state without losing the persistent thread/chat history

State preserved across restart:
- `state/thread.txt` (codex conversation continues from same point)
- `state/update_id.txt` (Telegram resumes from last processed message; no replay)

State NOT preserved:
- daemon's in-memory typing-pulse threads (any in-flight pulse is dropped, harmless)
- any current `codex exec` subprocess (terminated; if it was mid-turn, the answer is lost)

## How to invoke

The bridge daemon also accepts `/restart` as a Telegram admin command — that's the user-facing path. Programmatic / shell:

```
./restart.sh
```

Or from inside the agent's reasoning, advise the user to send `/restart`.
