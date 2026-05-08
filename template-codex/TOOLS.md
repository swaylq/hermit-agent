# TOOLS.md - Local Notes

_Record technical configs, API keys, tool settings, and operational notes here._

## Telegram

- 通过外置 Python 桥接 daemon 与用户沟通（不是 Claude Code 的 `--channels` plugin）
- 桥接脚本：`scripts/tg-bridge.py`
- chat_id: `{{USER_TG_ID}}`
- bot token 在 `{{STATE_DIR}}/.env` 里（mode 600，从不写到代码 / 日志 / 命令行）
- 桥接机制：daemon 每 ~25 秒长 poll `getUpdates`，对每条新消息调 `codex exec [resume <thread_id>] "<msg>"`，把 `--output-last-message` 拿到的最终回复发回 Telegram

## Codex CLI

- 已通过 ChatGPT 订阅认证（`codex login status` 应该返回 "Logged in using ChatGPT"）
- 全局配置 `~/.codex/config.toml`
- 启动方式：daemon 直接 `codex exec`，不需要长 tmux session（tmux 跑的是 daemon 本身）
- 标准 flag：`--json --output-last-message <file> --skip-git-repo-check`
- session 持久化：每个 thread 的 jsonl 在 `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<thread_id>.jsonl`，`codex exec resume <thread_id>` 从这里恢复

## State

- `state/thread.txt` — 当前对话的 thread_id（首条消息后 daemon 写入；后续消息走 resume）
- `state/update_id.txt` — 最后处理的 Telegram update_id（restart 后从此续订）
- `state/last.txt` — 最后一条 codex 输出（debug 用）
- 删除 `state/thread.txt` = 起新 thread（context 重置）

## Hooks (codex equivalent of Claude Code's lifecycle hooks)

Daemon 在三个时机调用 `scripts/hooks/<name>.sh`（exec 位 + 存在才跑）：

- `boot.sh` — daemon 启动一次。等价 SessionStart。无 env input。默认行为：写今日 daily log 启动时间戳；如果 `FIRST_RUN.md` 存在，发欢迎消息后删除
- `pre-run.sh` — 每次 `codex exec` 之前跑。env: `CODEX_PROMPT`, `CODEX_THREAD_ID`, `CODEX_CHAT_ID`。exit != 0 中止本轮。等价 UserPromptSubmit。默认行为：扫 prompt 里的 image 路径，对每个跑 `safe-image.sh`
- `post-run.sh` — codex 返回 reply 之后、daemon 发 Telegram 之前跑。env 多一个 `CODEX_REPLY`。stdout 非空时**替换** reply。等价 Stop。默认行为：写 daily log + 简单 strip markdown 标记

## Cron / launchd

样板：`cron/example-heartbeat.md` + `launchd/com.codex-hermit.{{AGENT_NAME}}.cron-heartbeat.plist`。

启用：
1. `launchctl load -w launchd/com.codex-hermit.{{AGENT_NAME}}.cron-heartbeat.plist`
2. 修改 `StartInterval` 调节频率
3. `scripts/run-cron.sh` wraps `codex exec` with `with-timeout.sh 1200`，自动报告结果到 Telegram

## Skills

`scripts/skills/` 是文档约定（不是 codex 自动加载机制）。当前：
- `restart` — 调 `./restart.sh`
- `provision-agent` — 占位，等待 `npx create-hermit-agent --host codex` 流程完善

新增 skill：mkdir + 写 `SKILL.md`，可选 `run.sh`。MCP-tool skill 在 `~/.codex/config.toml` `[mcp_servers.<name>]` 注册。

## Limits（订阅 vs API）

- ChatGPT Pro 20x ($200/mo): 300-1600 messages/5h window，理论一天 1440-7680 条
- 一次 `codex exec` 算几条 message 是要观察的指标——长 conversation 的 resume 每轮 cache hit ~80%
