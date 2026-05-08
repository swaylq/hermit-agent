<div align="center">

<img src="assets/logo.png" width="200" alt="Hermit Agent logo"/>

# Hermit Agent · 寄居蟹 Agent

**Anthropic 封锁了第三方订阅，所以做一只寄居蟹，把 agent 寄居在已有的 AI 编程 Host 上。默认寄居 [Claude Code](https://docs.claude.com/claude-code)；用 `--host codex` 也能寄居在 [OpenAI Codex CLI](https://developers.openai.com/codex/cli) 上，直接用你的 ChatGPT 订阅替代 API 花费。融合 Claude Code、Openclaw、Hermes Agent 三大 Harness 的优点，一行命令上手。**

[English](README.md) · [中文](README.zh-CN.md)

[![npm](https://img.shields.io/npm/v/create-hermit-agent?style=flat-square)](https://www.npmjs.com/package/create-hermit-agent)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow?style=flat-square)](LICENSE)
[![Node 18+](https://img.shields.io/badge/node-18%2B-green?style=flat-square)](https://nodejs.org)
[![macOS](https://img.shields.io/badge/platform-macOS-blue?style=flat-square)](https://www.apple.com/macos/)
[![Claude Code](https://img.shields.io/badge/host-Claude_Code-orange?style=flat-square)](https://docs.claude.com/claude-code)
[![Codex CLI](https://img.shields.io/badge/host-Codex_CLI-black?style=flat-square)](https://developers.openai.com/codex/cli)

</div>

---

## 融合三大框架

默认寄居 Claude Code，v0.1.38+ 起也支持 Codex CLI 作为 sibling host（详见 [Host 选择](#host-选择claude-code-还是-codex)）。

| 借鉴自 | 带来了什么 |
|---|---|
| **[Claude Code](https://docs.claude.com/claude-code)** | 默认壳本体。每个 agent 字面意义上就跑在 `claude --dangerously-skip-permissions` 里。Plugin、MCP、Tool、Hook 全部原生复用，什么都不重实现。 |
| **[Codex CLI](https://developers.openai.com/codex/cli)** _（用 `--host codex` opt-in）_ | 备选壳本体，让寄居蟹直接搭 ChatGPT 订阅。Codex 没有 `--channels` 这种 plugin push 模型，所以 hermit 自带 `scripts/tg-bridge.py` Python daemon，把 Telegram 消息翻译成 `codex exec` 调用。 |
| **OpenClaw** | 人格文件：`SOUL / IDENTITY / USER / AGENTS / TOOLS / MEMORY.md`；自管浏览器模式。塑形了 `scripts/chrome-launcher.sh`、`scripts/browser-lock.sh`，每个 agent 一个独立 Chrome profile 配 CDP 复用，外加 stealth 包装的 Playwright 套路。 |
| **Hermas Agent** | 自主进化模式和记忆模块设计。`SOUL.md` + `MEMORY.md` + 每日 `memory/YYYY-MM-DD.md` 日志 + 做梦式知识固化，全都继承自它。 |

---

## 30 秒上手

**默认（Claude Code host）：**

```bash
# 前置：Claude Code 已装并登录，Node 18+，brew install tmux jq，bun 已装
npx create-hermit-agent
cd asst && ./start.sh
```

**Codex host**（用你的 ChatGPT 订阅，不烧 API）：

```bash
# 前置：codex CLI 已装并 codex login，Node 18+，brew install tmux jq，python3
npx create-hermit-agent my-agent --host codex
cd my-agent && ./start.sh
```

> **Linux**：流程一样，把 `brew install tmux jq` 换成 `sudo apt install tmux jq curl`（或对应包管理器），并跑一次 `loginctl enable-linger $USER` 让 systemd-user timer 跨登出存活。Linux scaffold **故意精简**——不带 browser 和 image-safety 层。详见 [安装](#安装) 和 [FAQ](#faq) 章节。

打开 Telegram，DM 你刚在 @BotFather 注册的 bot。第一条 DM 会触发自我介绍——之后 agent 就不再骚扰你了。

> **你：** 下午 3 点提醒我给妈妈打电话  
> **asst：** 已安排，3 点 ping 你。

---

## 功能一览

| 能力 | 细节 |
|---|---|
| **Host 选择** | `--host claude`（默认）或 `--host codex`。Claude flavor 走 `@claude-plugins-official/telegram` 插件 + 完整 Claude Code 壳。Codex flavor 走 Python Telegram bridge daemon + ChatGPT 订阅的 `codex exec`。两边人设文件一致、记忆模式一致、hook 布局一致。 |
| **人设** | 每次启动都会读 `SOUL / IDENTITY / USER / AGENTS / TOOLS / MEMORY.md`。改文件即改 agent。Codex 原生自动加载 `AGENTS.md`；Claude Code 通过 `CLAUDE.md` 入口加载。 |
| **长期记忆** | 每日日志写到 `memory/YYYY-MM-DD.md`，长期策展在 `MEMORY.md`，重启跨越不丢。 |
| **Telegram I/O** | _Claude flavor_：走 `@claude-plugins-official/telegram` 原生 reply / react / edit / 下载附件，说人话直接路由到 slash 命令（「压缩上下文」→ `/compact`、「重启」→ `restart.sh`）。_Codex flavor_：Python bridge daemon 长 poll `getUpdates`，每条消息跑一次 `codex exec [resume <thread>]`，文本 + 自动检测的生成图片（`sendPhoto`）一并回。Daemon 层 admin 命令：`/help` `/status` `/reset` `/restart`。 |
| **Lifecycle** | `start.sh` + `restart.sh` 把 agent 包在命名的 `tmux` session 里——`claude-<name>`（claude flavor）或 `codex-<name>`（codex flavor）。两边都跨重启保留状态。 |
| **定时任务** | 三层——session-only 的 `cron` skill、跨重启的 `HEARTBEAT.md`、OS 持久的 `launchd` plist。Codex flavor 用 `scripts/run-cron.sh` 包 `codex exec` 在 `with-timeout.sh 1200` 里。 |
| **浏览器** | 独立 Chrome profile + CDP + Playwright + stealth-init 反检测（claude flavor）。Codex flavor 直接用其 bundle 的 `browser-use` plugin。 |
| **多 Agent** | `provision-agent` skill 在 `../<name>/` 生成 sibling 并给它独立 bot token。skill 识别「用 codex / 用 ChatGPT 订阅」并透传 `--host codex`，默认仍是 claude。可选每 10 分钟状态 digest 的 LaunchAgent。 |
| **安全** | 图片 Read 前强制过 `safe-image.sh` 缩图（长边 ≤ 1800px）。Token 存在 mode 600 的 repo 外文件（claude flavor 在 `~/.claude/channels/`，codex flavor 在 workspace 的 `.env`）。_Claude flavor_：Stop hook 阻止"收到 DM 没回就结束 turn"，PreToolUse hook 洗 markdown。_Codex flavor_：等价守护通过 `scripts/hooks/{boot,pre-run,post-run}.sh` 实现——boot 触发 `FIRST_RUN.md` 欢迎、pre-run 对检测到的图片路径跑 `safe-image.sh`、post-run 洗 markdown + 写 daily log。 |

---

## Host 选择：Claude Code 还是 Codex

CLI 的 `--host` 参数选 host，默认 `claude`。

```bash
npx create-hermit-agent my-agent                 # claude（默认）
npx create-hermit-agent my-agent --host codex    # codex
```

| | Claude flavor (`--host claude`) | Codex flavor (`--host codex`) |
|---|---|---|
| **底层 CLI** | `claude --dangerously-skip-permissions --channels plugin:telegram@…`（长跑 REPL，Telegram 消息通过 plugin 的 `--channels` 流入） | `codex exec --json --output-last-message <file> [resume <thread_id>]`（每轮一次性调用，daemon 协调） |
| **成本模型** | Anthropic API（claude.ai Pro 用 CLI + 按 token 计费 plugin session） | ChatGPT 订阅（Plus / Pro / Team / Enterprise——codex CLI 直接消费订阅的请求 budget） |
| **Telegram 桥接** | 原生——官方 `@claude-plugins-official/telegram` plugin 跑成 claude session 内的 `bun` MCP 子进程，把 Telegram 更新直接 push 到 REPL 当新 turn | 外置 Python daemon（`scripts/tg-bridge.py`，~250 行，stdlib only）长 poll `getUpdates`，每轮 `codex exec`，把 `--output-last-message` 通过 `sendMessage` 回。还自动检测 `~/.codex/generated_images/<thread>/` 里新增 png 用 `sendPhoto` 转发。 |
| **Lifecycle hooks** | Claude Code 原生 hook：`SessionStart` / `Stop` / `PreToolUse` / `UserPromptSubmit` 在 `.claude/settings.json` 里声明 | `scripts/hooks/{boot,pre-run,post-run}.sh` 由 bridge daemon 调用。boot ≈ SessionStart，pre-run ≈ UserPromptSubmit，post-run ≈ Stop。pre-run exit ≠ 0 中止本轮；post-run stdout 替换 reply（markdown 清理 / redaction） |
| **Slash / admin 命令** | 中英文人话路由经 `scripts/exec-cli-command.sh`（「压缩」→ `/compact`、「重启」→ `restart.sh $(cat agent.pid)`） | Daemon 直接拦截 `/help` `/status` `/reset` `/restart`，不调 codex |
| **Skills** | 自动从 `.claude/skills/` 加载（Claude Code 原生 skill protocol） | 文档约定写在 `scripts/skills/`（暂无 auto-loader，agent 主动读 `SKILLS.md` 或经 shell 调用）。Codex 自带的 `browser-use` / `documents` / `presentations` / `spreadsheets` 等 plugin 也并行可用。 |
| **MCP server** | 每 agent 在 `.claude/settings.local.json` | 每用户在 `~/.codex/config.toml` `[mcp_servers.<id>]` |
| **Cron / scheduler** | `claude --dangerously-skip-permissions -p "<prompt>"`（注意：`-p` 模式下 plugin sync 不 fire） | `scripts/run-cron.sh <task>` 读 `cron/<task>.md`，`codex exec` 在 `with-timeout.sh 1200` 下，结果直接 curl 回 Telegram |
| **状态** | `agent.pid` + Claude Code session 在 `~/.claude/projects/…` | `state/thread.txt`（当前 codex thread UUID）、`state/update_id.txt`（最后处理的 Telegram update_id）——都在 workspace 根，跨 restart 安全 |

什么时候选哪个：

- **Claude** —— 你想用官方 `--channels` 集成、slash 命令、完整 Claude Code skill 生态，并且能接受按 token 付费。
- **Codex** —— 你已经付了 ChatGPT 订阅，想把这个订阅 redirect 到 agent workload。能接受 polling-bridge 模型（每轮都是一次性 `codex exec`，通过 `~/.codex/sessions/` 持久化 thread）。不需要 Claude 专属的 plugin marketplace。

混用没问题——一台机器可以同时跑两种 flavor，各自占自己的 `tmux` session 和 bot token。

---

## 架构

```
┌────────────── 你的 Mac ──────────────┐       ┌─ Telegram ─┐
│                                       │       │            │
│  tmux session   claude-asst           │       │  Bot API   │
│  ┌───────────────────────────────┐   │       │            │
│  │  claude  （借来的壳）          │   │       │            │
│  │  ┌────────┐  ┌───────────────┐ │   │       │            │
│  │  │Persona │  │ Skills + Hooks│ │   │◄─────►│ @yourbot   │
│  │  │*.md    │  │ restart · cron│ │   │       │            │
│  │  │memory/ │  │ provision ... │ │   │       │            │
│  │  └────────┘  └───────────────┘ │   │       │            │
│  │     Telegram plugin (bun)      │   │       │            │
│  └────────────────────────────────┘   │       │            │
│                                       │       │            │
│  ~/.claude/channels/telegram-asst/    │       │            │
│    （token 存这里，不进 repo）         │       │            │
└───────────────────────────────────────┘       └────────────┘
```

高清 SVG：[assets/arch.svg](assets/arch.svg)。

---

## 安装

前置依赖（macOS，**claude flavor**）：

- [Claude Code](https://docs.claude.com/claude-code)——已装并登录（`claude login`）
- Node ≥ 18
- `brew install tmux jq`
- `curl -fsSL https://bun.sh/install | bash`

前置依赖（macOS，**codex flavor**）：

- [Codex CLI](https://developers.openai.com/codex/cli)——已装并登录（`codex login`，用 ChatGPT 帐号；`codex login status` 应返回 "Logged in using ChatGPT"）
- Node ≥ 18
- `python3`（系统自带或 `brew install python3`）
- `brew install tmux jq curl`

前置依赖（Linux，在 Ubuntu 22.04 上测过）：

- [Claude Code](https://docs.claude.com/claude-code)——已装并登录
- Node ≥ 18
- `sudo apt install tmux jq curl`（或 `dnf` / `pacman` / `apk` 对应命令）
- `curl -fsSL https://bun.sh/install | bash`
- 服务器一次性配置：`loginctl enable-linger $USER`，让 `systemd --user` timer 跨登出存活

Linux scaffold **不包含 browser 层**（chrome-launcher、browser-lock、playwright-mcp）和 **image-safety 层**（safe-image、pre-read-image hook）。这两块是 macOS 形状的（sips、`.app` 路径），v1 暂不跨平台移植——CLI 在 Linux 上 scaffold 时会自动 prune 这些脚本以及 `settings.json` / `settings.local.json` 里相关的 hook / MCP server / 权限条目。其他功能（Telegram plugin、人格、记忆、调度、多 agent 状态汇报）在两边都一样。**Codex flavor 在 Linux 上**也支持但测试覆盖较少——遇到问题欢迎提 issue。

脚手架：

```bash
# Claude flavor（默认）
npx create-hermit-agent

# Codex flavor
npx create-hermit-agent my-agent --host codex
```

CLI 会问你要 Telegram bot token（[@BotFather](https://t.me/BotFather)）和你自己的 Telegram user ID（[@userinfobot](https://t.me/userinfobot)）。

- **Claude flavor**：生成 `./asst/`，以 project scope 安装 telegram plugin，把 token 写到 mode 600 的 `~/.claude/channels/telegram-asst/.env`。
- **Codex flavor**：生成 `./my-agent/`，把 token 和 chat_id 写在 mode 600 的 workspace `.env` 里，复制 Python bridge daemon 和 hooks。不装 plugin——Telegram 桥是自包含的 Python 脚本。AGENTS.md 在每次 `codex exec` 时自动加载（Codex 原生行为）。

启动：

```bash
cd asst && ./start.sh             # claude flavor
cd my-agent && ./start.sh         # codex flavor
```

Agent 跑在一个 detached tmux session 里——`claude-<name>`（claude flavor）或 `codex-<name>`（codex flavor）。DM 你的 bot 即可。

---

## 第一条消息：asst 会自我介绍

第一次 DM 时 asst 会主动发一段简短引导——怎么跟它聊、哪些自然语言会触发内部命令（压缩上下文、重启、切模型、查状态等）、怎么开更多 agent——然后自己删掉 `FIRST_RUN.md`，以后不再骚扰你。

---

## 开更多 agent

**不要再跑一次 `npx create-hermit-agent`**。直接告诉 asst：

> 帮我新建一个叫 `github-bot` 的 agent，token `123:ABC…`，用来处理 GitHub 通知。

asst 的 `provision-agent` skill 会在 `../github-bot/` 生成 sibling、装它自己的 plugin、在 `claude-github-bot` tmux session 里启动，最后把新 bot 的 `@handle` 回给你。

Agent 之间完全独立：独立 bot token、独立记忆、独立目录。

---

## 自定义

在 agent 目录里改这几个：

| 文件 | 写什么 |
|---|---|
| `IDENTITY.md` | 名字、vibe、一句话使命 |
| `USER.md` | 你自己（pronouns、时区、备注） |
| `AGENTS.md` | `<!-- MISSION-START -->` 块——这个 agent 的具体任务 |
| `TOOLS.md` | `<!-- AGENT-SPECIFIC-START -->` 块——API key、repo 链接、领域知识 |

`SOUL.md` 是核心气质——除非真想换人格否则别碰。

---

## 定时任务

直接告诉 agent 要什么：

> 每 30 分钟扫一下 `memory/today.md`，标记 urgent 的条目。

asst 的 `cron` skill 会处理。跨重启的任务走 OS 级调度——macOS 用 `launchd`，Linux 用 `systemd --user`。

### macOS（launchd）

1. 在 agent 的 `launchd/` 目录放一份 plist——复制 `launchd/cron-example.plist.tmpl`，`Label` 改成 `com.hermit-agent.<agent>.cron-<task>`，`ProgramArguments` 指向你要跑的命令。真正执行的活外面包一层 `scripts/with-timeout.sh 1200`——20 分钟是天花板不是目标。
2. 同步到生效目录：`./scripts/launchd-sync.sh .`（幂等：新的 `LOADED`，改过的 `RELOAD`，一致的 skip；加 `--dry-run` 预览）。
3. 验证：`launchctl list | grep com.hermit-agent.<agent>`。

### Linux（systemd-user）

1. 在 agent 的 `systemd/` 目录放一对 `.service` + `.timer`——复制 `systemd/cron-example.service` 和 `systemd/cron-example.timer`，改 `ExecStart`（指向你的脚本）和 `OnUnitActiveSec`（间隔）。真正执行的活外面包一层 `scripts/with-timeout.sh 1200`。
2. 同步到 `~/.config/systemd/user/`：`./scripts/systemd-sync.sh .`（幂等：新的 `INSTALL`，改过的 `UPDATE`，一致的 skip；加 `--dry-run` 预览）。脚本会自动 `daemon-reload` 并 `enable --now` 每个 timer，没开 lingering 时会警告。
3. 验证：`systemctl --user list-timers 'hermit-<agent>-*'`，实时日志 `journalctl --user -u hermit-<agent>-<task>.service -f`。

光写文件不会生效——sync 脚本才是"生成"和"运行"之间的那一步。每次加、改、改名 unit 都要再跑一次。timeout 包装有必要：有条 cron 跑偏过一次，12h38m 卡住 3 个 fire 窗口才被人为杀掉。`AGENTS.md` → "Cron Safety" 讲清了纪律。

---

## 多 agent 状态汇报

CLI 在这台 Mac 上首次运行时会自动装一个 `launchd` coordinator。每 10 分钟 push 一次本机所有 hermit 的状态 digest 到 coordinator 的 Telegram：🟢 idle · 🟨 running · 🟥 stuck · ⚫ down。

- 每台 Mac 只有一个 coordinator。`create-hermit-agent` 发现已存在 `com.hermit-agent.*.status-reporter.plist` 就跳过，后续 hermit 不会各自再装一份。
- 第一个装的 agent（默认 `asst`）就是 coordinator。它的 plist 在 `~/Library/LaunchAgents/com.hermit-agent.asst.status-reporter.plist`。
- 想关：`launchctl unload ~/Library/LaunchAgents/com.hermit-agent.<coordinator>.status-reporter.plist`。
- 想换 coordinator：先 unload 老 plist 再 rm，然后从新 agent 再跑一次 `create-hermit-agent`（或手动 `cp launchd/status-reporter.plist ~/Library/LaunchAgents/com.hermit-agent.<new>.status-reporter.plist && launchctl load ...`）。

---

## 踩坑排查

| 症状 | 处理 |
|---|---|
| Agent 不回复 | `tmux attach -t claude-<name>` 看现场。也查 `restart.log`、`claude-agent.log`。 |
| Plugin subprocess 没起来 | `./restart.sh` 会自动重试一次。还不行就检查 `~/.claude/channels/telegram-<name>/.env` 是不是 mode 600 且有 token。 |
| `exceeds the dimension limit` 图片搞挂 | 所有 image Read 必须先过 `scripts/safe-image.sh`。挂了就重启 + `/compact` 恢复。 |
| `claude plugin install failed` | 确认 `claude` 在 PATH 上且已登录（`claude login`）。 |
| Context 爆 | Telegram 里说「压缩上下文」/「compact」/「精简一下」，agent 会通过 tmux 发 `/compact`。或者 pane 里直接敲 `/compact`。 |
| 新 Mac 上装完 bot 一直没反应 | Claude Code 可能弹了「trust this folder」或「允许 dangerous 模式」TUI 对话框卡在启动。CLI 会自动预先 ack 这两个，但万一失败：`tmux attach -t claude-<name>` 进去回车 dismiss 掉对话框，然后 Ctrl-b d 退出。 |

---

## FAQ

**Claude Code 需不需要预装 telegram plugin？**  
不需要。`create-hermit-agent` 每次创建都会跑 `claude plugin install telegram@claude-plugins-official -s project`。首次从 marketplace 下到共享缓存 `~/.claude/plugins/cache/`，之后新 agent 只做 per-project 注册。你这边零预装。

**Linux / Windows 支持吗？**  
**Linux**：支持，但有取舍。CLI 自动检测平台，Linux v1 ship 一个**精简版**——没有 browser 层，也没有 image-safety 层（这两个是 macOS 形状的：sips、`.app` 路径、专门给 macOS 上 Chrome 调过的 Playwright 集成）。CLI 在 Linux scaffold 时会自动把对应脚本 + `settings.json` / `settings.local.json` 里的 hook / MCP server / 权限条目都 prune 掉，agent 目录不会留死代码。调度走 `systemd --user` 而不是 `launchd`。其他（Telegram plugin、人格、记忆、多 agent 状态汇报、`cron -p` 的 Bot API push 路径）都跟 macOS 一样。  
**Windows**：不支持。WSL2 理论可行（本质是 Linux）但没测过。

**多 agent 能共用一个 bot token 吗？**  
不行。Telegram Bot API 给每个 bot 的 update 只发给一个 listener。共用 token 会导致某个 agent 把另一个的消息“劫持”走。每个 agent 必须用 `@BotFather` 单独发的 token。

**Bot token 存在哪？**  
`~/.claude/channels/telegram-<name>/.env`（mode 600，项目外面）。也在 `.claude/settings.local.json` 里（已 gitignore）。

**第一条 DM 会触发 pairing code 吗？**  
不会。CLI 会在 `~/.claude/channels/telegram-<name>/access.json` 里把你的 user ID 预置进 allowlist，所以你自己的 DM 从第一条开始就直通。陌生人摸到 bot `@handle` 发 DM 还是会走 pairing 流程（`dmPolicy: "pairing"`），不会被静默投递进来。

**怎么干净删一个 agent？**

```bash
# macOS：
launchctl unload ~/Library/LaunchAgents/com.hermit-agent.<name>.*.plist 2>/dev/null
rm -f ~/Library/LaunchAgents/com.hermit-agent.<name>.*.plist

# Linux：
for u in ~/.config/systemd/user/hermit-<name>-*.{service,timer}; do
  [ -f "$u" ] && systemctl --user disable --now "$(basename "$u")"
done
rm -f ~/.config/systemd/user/hermit-<name>-*.{service,timer}
systemctl --user daemon-reload

# 两个平台都需要：
tmux kill-session -t claude-<name> 2>/dev/null
rm -rf <agent-folder>
rm -rf ~/.claude/channels/telegram-<name>
```

Bot 不用了顺手去 `@BotFather` revoke 掉。

---

## License

[MIT](LICENSE)。
