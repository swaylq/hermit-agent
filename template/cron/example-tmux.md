# Example cron prompt — designed for `claude-tmux-run.sh`

This is the prompt a `claude-tmux-run.sh`-driven cron task would receive. The pattern is the same as `cron/example.md` (single-shot, on-prompt, log + Telegram at end), but the response is collected by tmux pane scrape rather than `-p` stdout — so the prompt asks claude to **emit a fixed marker string around the part the cron is supposed to extract**.

Replace this file with the actual task content; the marker convention is the only thing the runner relies on.

---

<task preamble>
先静默读 SOUL/IDENTITY/USER/AGENTS/TOOLS/MEMORY.md + memory/$(date +%Y-%m-%d).md（如存在），建立上下文。不要复述读了什么。

Telegram 回复禁用 markdown。

这次的运行容器是 `claude-tmux-run.sh`，不是 `claude -p`：
- session 跑在 ephemeral tmux 里，turn 完成后会被外部脚本 capture-pane 抓全屏 scroll-back。
- 想给外部脚本 grep 的内容用 `BEGIN_RESULT` / `END_RESULT` 两行把结果框起来，外部就能 `awk '/^BEGIN_RESULT/,/^END_RESULT/'` 拿到。
- 想 Telegram 汇报的另发一条 `mcp__plugin_telegram_telegram__reply` —— **不可用，因为本会话没加载 channels plugin**。改走 Bot API 直 curl：
  ```bash
  TOKEN=$(jq -r '.env.TELEGRAM_BOT_TOKEN' .claude/settings.local.json)
  curl -sS "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    --data-urlencode "chat_id=<your_chat_id>" \
    --data-urlencode "text=<message>"
  ```
</task preamble>

任务: <在这里替换成你的实际任务，例：「扫今天的 memory/YYYY-MM-DD.md，挑出 3 条最重要的事，输出 JSON `[{title, why}, ...]`」>

输出格式: 直接打印结果，用 `BEGIN_RESULT` / `END_RESULT` 包起来。例如:

```
BEGIN_RESULT
[
  {"title": "...", "why": "..."},
  ...
]
END_RESULT
```

<task postamble>
完成后:
1. 追加简短日志到 memory/$(date +%Y-%m-%d).md（做了什么 / 结果 / 异常）
2. Bot API curl 一条 1-3 句汇报到你的 chat_id（纯文本，无 markdown）
3. 打印 BEGIN_RESULT / END_RESULT 包住的结果块。完成后回到 `❯` 等 runner 退出。
</task postamble>
