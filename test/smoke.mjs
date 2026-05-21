// Smoke test: copy template into /tmp/hermit-smoke-out/ with dummy placeholders
// and sanity-check a few known substitutions.

import { existsSync, rmSync, readFileSync, readdirSync, mkdirSync, writeFileSync, chmodSync, statSync, renameSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const TEMPLATE_DIR = resolve(__dirname, '..', 'template');
const TEMPLATE_CODEX_DIR = resolve(__dirname, '..', 'template-codex');
const TARGET = '/tmp/hermit-smoke-out';
const TARGET_CODEX = '/tmp/hermit-smoke-codex';

const TEXT_EXTS = new Set(['.md', '.json', '.js', '.ts', '.sh', '.bash', '.zsh', '.plist', '.toml', '.yml', '.yaml', '.tmpl', '.gitkeep', '.gitignore']);
function isTextFile(path) {
  if (path.endsWith('.gitignore') || path.endsWith('.gitkeep')) return true;
  const i = path.lastIndexOf('.');
  if (i < 0) return true;
  return TEXT_EXTS.has(path.slice(i));
}
function substitute(content, vars) {
  return content.replace(/\{\{(\w+)\}\}/g, (m, key) => (key in vars ? vars[key] : m));
}
function walkCopy(srcDir, destDir, vars) {
  if (!existsSync(destDir)) mkdirSync(destDir, { recursive: true });
  for (const entry of readdirSync(srcDir, { withFileTypes: true })) {
    const srcPath = join(srcDir, entry.name);
    let destName = entry.name;
    if (destName.endsWith('.tmpl')) destName = destName.slice(0, -5);
    const destPath = join(destDir, destName);
    if (entry.isDirectory()) walkCopy(srcPath, destPath, vars);
    else if (entry.isFile()) {
      if (isTextFile(srcPath)) {
        writeFileSync(destPath, substitute(readFileSync(srcPath, 'utf8'), vars));
      } else {
        writeFileSync(destPath, readFileSync(srcPath));
      }
      try { chmodSync(destPath, statSync(srcPath).mode); } catch {}
    }
  }
}

if (existsSync(TARGET)) rmSync(TARGET, { recursive: true, force: true });

const vars = {
  AGENT_NAME:         'smoke-test',
  AGENT_DISPLAY_NAME: 'Smoke Test',
  PERSONA:            'automated smoke-test agent',
  USER_NAME:          'Tester',
  USER_TG_ID:         '9999999',
  TG_BOT_TOKEN:       '<<DUMMY_TOKEN>>',
  BRAVE_API_KEY:      '',
  AGENT_DIR:          TARGET,
  STATE_DIR:          '/tmp/hermit-smoke-state',
  CLAUDE_BIN:         '/usr/local/bin/claude',
  HOME:               process.env.HOME || '',
};

walkCopy(TEMPLATE_DIR, TARGET, vars);

// Assertions
const checks = [
  ['settings.json has substituted AGENT_DIR',
    readFileSync(join(TARGET, '.claude/settings.json'), 'utf8').includes(`"Write(${TARGET}/**)"`)],
  ['settings.local.json exists (no .tmpl)',
    existsSync(join(TARGET, '.claude/settings.local.json'))],
  ['settings.local.json has substituted TG_BOT_TOKEN',
    readFileSync(join(TARGET, '.claude/settings.local.json'), 'utf8').includes('<<DUMMY_TOKEN>>')],
  ['settings.local.json has substituted CHAT_ID',
    readFileSync(join(TARGET, '.claude/settings.local.json'), 'utf8').includes('"TELEGRAM_CHAT_ID": "9999999"')],
  ['CLAUDE.md trimmed (no Memory/Skills/Workspace sections)',
    (() => {
      const c = readFileSync(join(TARGET, 'CLAUDE.md'), 'utf8');
      return !c.includes('## Memory') && !c.includes('## Skills') && !c.includes('## Workspace');
    })()],
  ['IDENTITY.md has substituted display name',
    readFileSync(join(TARGET, 'IDENTITY.md'), 'utf8').includes('Smoke Test')],
  ['TOOLS.md has substituted USER_TG_ID',
    readFileSync(join(TARGET, 'TOOLS.md'), 'utf8').includes('9999999')],
  ['restart.sh has substituted CLAUDE_BIN',
    readFileSync(join(TARGET, 'restart.sh'), 'utf8').includes('/usr/local/bin/claude')],
  ['start.sh exists and is executable',
    (() => { try { return (statSync(join(TARGET, 'start.sh')).mode & 0o111) !== 0; } catch { return false; } })()],
  ['safe-image.sh is executable',
    (() => { try { return (statSync(join(TARGET, 'scripts/safe-image.sh')).mode & 0o111) !== 0; } catch { return false; } })()],
  ['tg-reply-check.sh exists and is executable',
    (() => { try { return (statSync(join(TARGET, '.claude/hooks/tg-reply-check.sh')).mode & 0o111) !== 0; } catch { return false; } })()],
  ['browser/utils/human-like.js present',
    existsSync(join(TARGET, 'scripts/browser/utils/human-like.js'))],
  ['launchd plist substituted',
    readFileSync(join(TARGET, 'launchd/status-reporter.plist'), 'utf8').includes(`com.hermit-agent.smoke-test.status-reporter`)],
  ['no stray {{ placeholder in CLAUDE.md',
    !readFileSync(join(TARGET, 'CLAUDE.md'), 'utf8').includes('{{')],
  ['no stray {{ in IDENTITY.md',
    !readFileSync(join(TARGET, 'IDENTITY.md'), 'utf8').includes('{{')],
  ['no stray {{ in TOOLS.md',
    !readFileSync(join(TARGET, 'TOOLS.md'), 'utf8').includes('{{')],
  ['skills/provision-agent/SKILL.md present',
    existsSync(join(TARGET, '.claude/skills/provision-agent/SKILL.md'))],
  ['skills/add-telegram-user/SKILL.md present',
    existsSync(join(TARGET, '.claude/skills/add-telegram-user/SKILL.md'))],
  ['add-telegram-user frontmatter has owner-only description',
    readFileSync(join(TARGET, '.claude/skills/add-telegram-user/SKILL.md'), 'utf8').includes('Owner-only')],
  ['FIRST_RUN.md present with substituted AGENT_DIR',
    existsSync(join(TARGET, 'FIRST_RUN.md')) &&
    readFileSync(join(TARGET, 'FIRST_RUN.md'), 'utf8').includes(TARGET)],
  ['cron-example plist substituted AGENT_DIR + AGENT_NAME',
    existsSync(join(TARGET, 'launchd/cron-example.plist')) &&
    readFileSync(join(TARGET, 'launchd/cron-example.plist'), 'utf8').includes(`com.hermit-agent.smoke-test.`) &&
    readFileSync(join(TARGET, 'launchd/cron-example.plist'), 'utf8').includes(TARGET)],
  ['cron-example plist includes EnvironmentVariables PATH with substituted HOME',
    (() => {
      const p = join(TARGET, 'launchd/cron-example.plist');
      if (!existsSync(p)) return false;
      const s = readFileSync(p, 'utf8');
      return s.includes('<key>EnvironmentVariables</key>')
        && s.includes(`${process.env.HOME}/.local/bin`)
        && !s.includes('{{HOME}}');
    })()],
  ['idle-hibernator.plist substituted (label + AGENT_DIR + HIBERNATOR_SELF)',
    existsSync(join(TARGET, 'launchd/idle-hibernator.plist')) &&
    (() => {
      const s = readFileSync(join(TARGET, 'launchd/idle-hibernator.plist'), 'utf8');
      return s.includes('com.hermit-agent.smoke-test.idle-hibernator')
        && s.includes(`${TARGET}/scripts/idle-hibernator.sh`)
        && s.includes('<key>HIBERNATOR_SELF</key>')
        && s.includes('<string>smoke-test</string>');
    })()],
  ['wake-poller.plist substituted (label + AGENT_DIR + 60s interval)',
    existsSync(join(TARGET, 'launchd/wake-poller.plist')) &&
    (() => {
      const s = readFileSync(join(TARGET, 'launchd/wake-poller.plist'), 'utf8');
      return s.includes('com.hermit-agent.smoke-test.wake-poller')
        && s.includes(`${TARGET}/scripts/wake-poller.sh`)
        && s.includes('<integer>60</integer>');
    })()],
  ['hibernate-agent.sh + wake-agent.sh + idle-hibernator.sh + wake-poller.sh executable',
    (() => {
      try {
        for (const f of ['hibernate-agent.sh', 'wake-agent.sh', 'idle-hibernator.sh', 'wake-poller.sh']) {
          if ((statSync(join(TARGET, 'scripts', f)).mode & 0o111) === 0) return false;
        }
        return true;
      } catch { return false; }
    })()],
  ['hibernate-agent.sh derives PROJ_DIR from agents_root_enc (portable convention)',
    readFileSync(join(TARGET, 'scripts/hibernate-agent.sh'), 'utf8').includes('agents_root_enc=$(echo "$AGENTS_ROOT" | sed')],
  ['idle-hibernator.sh respects HIBERNATOR_SELF env',
    readFileSync(join(TARGET, 'scripts/idle-hibernator.sh'), 'utf8').includes('HIBERNATOR_SELF')],
  ['wake-agent.sh auto-dismisses Resume-from-summary modal',
    readFileSync(join(TARGET, 'scripts/wake-agent.sh'), 'utf8').includes('Resume from summary')],
  ['multi-agent-status-report.sh recognizes paused.json (💤 hibernated)',
    readFileSync(join(TARGET, 'scripts/multi-agent-status-report.sh'), 'utf8').includes('💤') &&
    readFileSync(join(TARGET, 'scripts/multi-agent-status-report.sh'), 'utf8').includes('paused.json')],
  ['reap-dead-sessions.plist substituted (label + script path + 04:10 schedule)',
    existsSync(join(TARGET, 'launchd/reap-dead-sessions.plist')) &&
    (() => {
      const s = readFileSync(join(TARGET, 'launchd/reap-dead-sessions.plist'), 'utf8');
      return s.includes('com.hermit-agent.smoke-test.reap-dead-sessions')
        && s.includes(`${TARGET}/scripts/reap-dead-sessions.sh`)
        && s.includes('<key>StartCalendarInterval</key>')
        && s.includes('<integer>4</integer>')
        && s.includes('<integer>10</integer>');
    })()],
  ['reap-dead-sessions.sh executable',
    (() => { try { return (statSync(join(TARGET, 'scripts/reap-dead-sessions.sh')).mode & 0o111) !== 0; } catch { return false; } })()],
  ['reap-dead-sessions.sh derives PROJ_DIR from agents_root_enc (portable convention)',
    readFileSync(join(TARGET, 'scripts/reap-dead-sessions.sh'), 'utf8').includes('agents_root_enc=$(echo "$AGENTS_ROOT" | sed')],
  ['reap-dead-sessions.sh checks both session-status.json and paused.json before reaping',
    (() => {
      const s = readFileSync(join(TARGET, 'scripts/reap-dead-sessions.sh'), 'utf8');
      return s.includes('session-status.json') && s.includes('paused.json') && s.includes('is_protected');
    })()],
  ['reap-dead-sessions.sh refuses to run without a trash backend',
    (() => {
      const s = readFileSync(join(TARGET, 'scripts/reap-dead-sessions.sh'), 'utf8');
      return s.includes('no trash backend') && s.includes('gio trash');
    })()],
  ['systemd/reap-dead-sessions.timer fires daily at 04:10',
    (() => {
      const p = join(TARGET, 'systemd/reap-dead-sessions.timer');
      if (!existsSync(p)) return false;
      const s = readFileSync(p, 'utf8');
      return s.includes('OnCalendar=*-*-* 04:10:00')
        && s.includes('hermit-smoke-test-reap-dead-sessions.service');
    })()],
  ['AGENTS.md documents the reap-dead-sessions sweep',
    readFileSync(join(TARGET, 'AGENTS.md'), 'utf8').includes('Dead-session reaper')],
  ['multi-agent-status-report.sh skips self status-reporter to avoid 0s noise',
    readFileSync(join(TARGET, 'scripts/multi-agent-status-report.sh'), 'utf8').includes('SELF_STATUS_REPORTER_LABEL')],
  ['multi-agent-status-report.sh has check_cron_mtime + reap-dead-sessions hookup',
    (() => {
      const s = readFileSync(join(TARGET, 'scripts/multi-agent-status-report.sh'), 'utf8');
      return s.includes('check_cron_mtime') && s.includes('reap-dead-sessions') && s.includes('86400');
    })()],
  ['multi-agent-status-report.sh check_interval_agent log-mtime fallback survives reboot',
    (() => {
      const s = readFileSync(join(TARGET, 'scripts/multi-agent-status-report.sh'), 'utf8');
      return s.includes('effective_runs') && s.includes('log_mtime');
    })()],
  ['hook-block-askuserquestion.sh present, executable, denies AskUserQuestion',
    (() => {
      try {
        const p = join(TARGET, 'scripts/hook-block-askuserquestion.sh');
        if ((statSync(p).mode & 0o111) === 0) return false;
        const s = readFileSync(p, 'utf8');
        return s.includes('"AskUserQuestion"') && s.includes('"deny"');
      } catch { return false; }
    })()],
  ['settings.local.json wires AskUserQuestion → hook-block-askuserquestion.sh',
    (() => {
      const p = join(TARGET, '.claude/settings.local.json');
      if (!existsSync(p)) return false;
      const s = readFileSync(p, 'utf8');
      return s.includes('"matcher": "AskUserQuestion"')
        && s.includes('hook-block-askuserquestion.sh');
    })()],
  ['AGENTS.md forbids AskUserQuestion in Telegram Replies rules',
    readFileSync(join(TARGET, 'AGENTS.md'), 'utf8').includes('Never call AskUserQuestion')],
  ['chrome-launcher.sh deterministic_port hashes agent name',
    (() => {
      const s = readFileSync(join(TARGET, 'scripts/chrome-launcher.sh'), 'utf8');
      return s.includes('deterministic_port') && s.includes('cksum') && s.includes('% 100');
    })()],
  ['chrome-launcher.sh forces IPv4-only via --remote-debugging-address',
    readFileSync(join(TARGET, 'scripts/chrome-launcher.sh'), 'utf8').includes('--remote-debugging-address=127.0.0.1')],
  ['chrome-launcher.sh sibling_owns_port cross-checks chrome.json files',
    (() => {
      const s = readFileSync(join(TARGET, 'scripts/chrome-launcher.sh'), 'utf8');
      return s.includes('sibling_owns_port') && s.includes('chrome.json');
    })()],
  ['multi-agent-status-report.sh detects chrome-cdp port collisions',
    (() => {
      const s = readFileSync(join(TARGET, 'scripts/multi-agent-status-report.sh'), 'utf8');
      return s.includes('cdp_port_owners') && s.includes('chrome-cdp') && s.includes('collision');
    })()],
  ['patch-telegram-plugin.sh present, executable, idempotent',
    (() => {
      try {
        const p = join(TARGET, 'scripts/patch-telegram-plugin.sh');
        if ((statSync(p).mode & 0o111) === 0) return false;
        const s = readFileSync(p, 'utf8');
        return s.includes('bootPpid') && s.includes('already patched') && s.includes('marketplaces/claude-plugins-official');
      } catch { return false; }
    })()],
  ['start.sh + restart.sh call patch-telegram-plugin.sh before bun spawn',
    (() => {
      const start = readFileSync(join(TARGET, 'start.sh'), 'utf8');
      const restart = readFileSync(join(TARGET, 'restart.sh'), 'utf8');
      return start.includes('patch-telegram-plugin.sh') && restart.includes('patch-telegram-plugin.sh');
    })()],
  ['AGENTS.md has FIRST_RUN orientation rule',
    readFileSync(join(TARGET, 'AGENTS.md'), 'utf8').includes('If `FIRST_RUN.md` exists')],
  ['hook-tg-strip-markdown.sh exists and is executable',
    (() => { try { return (statSync(join(TARGET, 'scripts/hook-tg-strip-markdown.sh')).mode & 0o111) !== 0; } catch { return false; } })()],
  ['launchd-sync.sh exists and is executable',
    (() => { try { return (statSync(join(TARGET, 'scripts/launchd-sync.sh')).mode & 0o111) !== 0; } catch { return false; } })()],
  ['launchd-sync.sh takes agent-dir arg and has LOADED/RELOAD verbs',
    (() => {
      const s = readFileSync(join(TARGET, 'scripts/launchd-sync.sh'), 'utf8');
      return s.includes('Usage:') && s.includes('LOADED') && s.includes('RELOAD') && s.includes('launchctl load');
    })()],
  ['migrate-openclaw skill present and user-invocable',
    (() => {
      const p = join(TARGET, '.claude/skills/migrate-openclaw/SKILL.md');
      if (!existsSync(p)) return false;
      const s = readFileSync(p, 'utf8');
      return s.includes('user_invocable: true')
        && s.includes('launchd-sync.sh')
        && s.includes('~/.openclaw/')
        && s.includes('com.hermit-agent.');
    })()],
  ['with-timeout.sh exists and is executable',
    (() => { try { return (statSync(join(TARGET, 'scripts/with-timeout.sh')).mode & 0o111) !== 0; } catch { return false; } })()],
  ['with-timeout.sh has watchdog + timeout-124 semantics',
    (() => {
      const s = readFileSync(join(TARGET, 'scripts/with-timeout.sh'), 'utf8');
      return s.includes('kill -TERM') && s.includes('kill -KILL') && s.includes('exit 124');
    })()],
  ['claude-tmux-run.sh exists and is executable',
    (() => { try { return (statSync(join(TARGET, 'scripts/claude-tmux-run.sh')).mode & 0o111) !== 0; } catch { return false; } })()],
  ['claude-tmux-run.sh has tmux + idle-poll + timeout semantics',
    (() => {
      const s = readFileSync(join(TARGET, 'scripts/claude-tmux-run.sh'), 'utf8');
      return s.includes('tmux new-session')
        && s.includes('paste-buffer')
        && s.includes('capture-pane')
        && s.includes('idle_streak')
        && s.includes('exit 124');
    })()],
  ['cron/example-tmux.md present with BEGIN_RESULT marker convention',
    (() => {
      try {
        const s = readFileSync(join(TARGET, 'cron/example-tmux.md'), 'utf8');
        return s.includes('BEGIN_RESULT') && s.includes('END_RESULT');
      } catch { return false; }
    })()],
  ['cron-example plist invokes claude-tmux-run.sh (not raw claude -p)',
    (() => {
      const s = readFileSync(join(TARGET, 'launchd/cron-example.plist'), 'utf8');
      // Pull just the ProgramArguments command line; tolerate the comment
      // block above it, which legitimately mentions `claude -p` for context.
      const m = s.match(/<key>ProgramArguments<\/key>[\s\S]*?<\/array>/);
      if (!m) return false;
      const cmd = m[0];
      return cmd.includes('claude-tmux-run.sh') && !/\bclaude\s+-p\b/.test(cmd);
    })()],
  ['systemd cron-example.service invokes claude-tmux-run.sh',
    (() => {
      const s = readFileSync(join(TARGET, 'systemd/cron-example.service'), 'utf8');
      return s.includes('claude-tmux-run.sh');
    })()],
  ['AGENTS.md carries Token Safety section',
    (() => {
      const s = readFileSync(join(TARGET, 'AGENTS.md'), 'utf8');
      return s.includes('## Token Safety') && s.includes('Never grep or find the filesystem for tokens') && s.includes('Never echo / print / log a token');
    })()],
  ['AGENTS.md carries Cron Safety section referring to with-timeout.sh',
    (() => {
      const s = readFileSync(join(TARGET, 'AGENTS.md'), 'utf8');
      return s.includes('## Cron Safety') && s.includes('with-timeout.sh 1200') && s.includes('Stay strictly on-prompt');
    })()],
  ['AGENTS.md Cron Safety prefers claude-tmux-run.sh + flags June 15 billing split',
    (() => {
      const s = readFileSync(join(TARGET, 'AGENTS.md'), 'utf8');
      return s.includes('claude-tmux-run.sh') && s.includes('2026-06-15') && s.includes('Agent SDK');
    })()],
  ['AGENTS.md Shell Safety bans find on ~/Library and wide pipes',
    (() => {
      const s = readFileSync(join(TARGET, 'AGENTS.md'), 'utf8');
      return s.includes('Never `find /Users/<you>`') && s.includes('find | xargs grep') && s.includes('-maxdepth 3');
    })()],
  ['AGENTS.md Shell Safety also bans wide Glob/Grep tool patterns',
    (() => {
      const s = readFileSync(join(TARGET, 'AGENTS.md'), 'utf8');
      return s.includes('Glob tool') && s.includes('Grep tool')
        && s.includes('ripgrep')
        && s.includes('Three documented incidents')
        && s.includes('`/Users/<you>/**`');
    })()],
  ['hook-context-report.sh hardened: 50MB cap + with-timeout wrapping',
    (() => {
      const s = readFileSync(join(TARGET, 'scripts/hook-context-report.sh'), 'utf8');
      return s.includes('MAX_TRANSCRIPT_BYTES') && s.includes('50 * 1024 * 1024')
        && s.includes('with-timeout.sh') && s.includes('"$WITH_TIMEOUT" 3');
    })()],
  ['AGENTS.md has CLI Commands via Natural Language (no !! sigil, includes restart)',
    (() => {
      const s = readFileSync(join(TARGET, 'AGENTS.md'), 'utf8');
      return s.includes('## CLI Commands via Natural Language')
        && s.includes('exec-cli-command.sh')
        && s.includes('"重启" / "restart"')
        && s.includes('./restart.sh $(cat agent.pid)')
        && !s.includes('Telegram Sigil')
        && !s.includes('`!!compact`')
        && !s.includes('`!!clear`');
    })()],
  ['FIRST_RUN.md uses natural-language examples (no !!)',
    (() => {
      const s = readFileSync(join(TARGET, 'FIRST_RUN.md'), 'utf8');
      return s.includes('压缩上下文') && s.includes('重启') && !s.includes('!!compact');
    })()],
  ['cron-example plist wraps real work in with-timeout.sh',
    (() => {
      const s = readFileSync(join(TARGET, 'launchd/cron-example.plist'), 'utf8');
      return s.includes('./scripts/with-timeout.sh 1200');
    })()],
  ['AGENTS.md carries MCP Registry Safety section',
    (() => {
      const s = readFileSync(join(TARGET, 'AGENTS.md'), 'utf8');
      return s.includes('## MCP Registry Safety')
        && s.includes('claude mcp add')
        && s.includes('invalidates EVERY deferred MCP tool schema')
        && s.includes('./restart.sh')
        && s.includes('NOT a substitute');
    })()],
  ['settings.local.json wires markdown-strip hook for telegram reply+edit',
    (() => {
      const s = JSON.parse(readFileSync(join(TARGET, '.claude/settings.local.json'), 'utf8'));
      const pre = s.hooks?.PreToolUse || [];
      const match = pre.find(e => e.matcher && e.matcher.includes('mcp__plugin_telegram_telegram__reply') && e.matcher.includes('mcp__plugin_telegram_telegram__edit_message'));
      return !!match && match.hooks?.some(h => h.command?.includes('hook-tg-strip-markdown.sh'));
    })()],
  ['pre-read-image.sh exists and is executable',
    (() => { try { return (statSync(join(TARGET, 'scripts/hooks/pre-read-image.sh')).mode & 0o111) !== 0; } catch { return false; } })()],
  ['pre-read-image.sh blocks oversized images via exit 2 + sips dims',
    (() => {
      const s = readFileSync(join(TARGET, 'scripts/hooks/pre-read-image.sh'), 'utf8');
      return s.includes('DIM_LIMIT=2000')
        && s.includes("tool_name = \"Read\"".replace(/"/g,'"')) || s.includes('tool_name" = "Read"')
        || (s.includes('tool_name') && s.includes('Read') && s.includes('exit 2') && s.includes('sips -g pixelWidth') && s.includes('safe-image.sh'));
    })()],
  ['settings.local.json wires Read matcher to pre-read-image.sh',
    (() => {
      const s = JSON.parse(readFileSync(join(TARGET, '.claude/settings.local.json'), 'utf8'));
      const pre = s.hooks?.PreToolUse || [];
      const match = pre.find(e => e.matcher === 'Read');
      return !!match && match.hooks?.some(h => h.command?.includes('pre-read-image.sh'));
    })()],
  ['AGENTS.md Image Safety describes layered defense with hook as Layer 1',
    (() => {
      const s = readFileSync(join(TARGET, 'AGENTS.md'), 'utf8');
      return s.includes('## Image Safety')
        && s.includes('Layer 1 — mechanical')
        && s.includes('pre-read-image.sh')
        && s.includes('fail-closed');
    })()],
  ['multi-agent-status-report.sh has pane_state_check self-heal',
    (() => {
      const s = readFileSync(join(TARGET, 'scripts/multi-agent-status-report.sh'), 'utf8');
      return s.includes('pane_state_check()')
        && s.includes('tmux has-session')
        && s.includes('tmux capture-pane')
        && s.includes('healed_')
        && s.includes('Stop hook likely missed');
    })()],
  ['AGENTS.md MCP Registry Safety has cron -p Bot API exception',
    (() => {
      const s = readFileSync(join(TARGET, 'AGENTS.md'), 'utf8');
      return s.includes('Cron -p exception')
        && s.includes("by design don't run plugin sync")
        && s.includes('is **permitted**');
    })()],
  ['multi-agent-status-report.sh has stuck-escalation tier (🆘 CRITICAL)',
    (() => {
      const s = readFileSync(join(TARGET, 'scripts/multi-agent-status-report.sh'), 'utf8');
      return s.includes('stuck_counts')
        && s.includes('prev_stuck_counts_json')
        && s.includes('🆘')
        && s.includes('CRITICAL stuck')
        && s.includes('consider restart');
    })()],
  ['claude-quota-probe.sh exists and is executable',
    (() => {
      const p = join(TARGET, 'scripts/claude-quota-probe.sh');
      try {
        const stat = statSync(p);
        return stat.isFile() && (stat.mode & 0o111) !== 0;
      } catch { return false; }
    })()],
  ['multi-agent-status-report.sh has claude code usage section',
    (() => {
      const s = readFileSync(join(TARGET, 'scripts/multi-agent-status-report.sh'), 'utf8');
      return s.includes('claude code')
        && s.includes('claude-quota-probe.sh')
        && s.includes('ccusage')
        && s.includes('usage_lines');
    })()],
  // launchd default PATH is /usr/bin:/bin:/usr/sbin:/sbin and the Claude Code
  // installer puts the binary at ~/.local/bin/claude, so both scripts need to
  // prepend that explicitly or the probe silently fails (issue caught on a
  // fresh hermit install at v0.1.26).
  ['multi-agent-status-report.sh PATH includes ~/.local/bin',
    (() => {
      const s = readFileSync(join(TARGET, 'scripts/multi-agent-status-report.sh'), 'utf8');
      return /export PATH=\$HOME\/\.local\/bin:/.test(s);
    })()],
  ['claude-quota-probe.sh PATH includes ~/.local/bin',
    (() => {
      const s = readFileSync(join(TARGET, 'scripts/claude-quota-probe.sh'), 'utf8');
      return /export PATH=\$HOME\/\.local\/bin:/.test(s);
    })()],
  ['provision-clone skill exists with npx flow',
    (() => {
      const p = join(TARGET, '.claude/skills/provision-clone/SKILL.md');
      if (!existsSync(p)) return false;
      const s = readFileSync(p, 'utf8');
      return s.includes('npx create-hermit-agent --clone-of')
        && s.includes('doppel')
        && s.includes('symlink');
    })()],
  ['provision-agent skill names master/worker roles',
    (() => {
      const s = readFileSync(join(TARGET, '.claude/skills/provision-agent/SKILL.md'), 'utf8');
      return s.includes('master') && s.includes('worker');
    })()],
  ['provision-clone skill names master/worker roles',
    (() => {
      const s = readFileSync(join(TARGET, '.claude/skills/provision-clone/SKILL.md'), 'utf8');
      return s.includes('Doppels are always') && s.includes('workers');
    })()],
  ['cron skill has Loop Tasks section',
    (() => {
      const p = join(TARGET, '.claude/skills/cron/SKILL.md');
      if (!existsSync(p)) return false;
      const s = readFileSync(p, 'utf8');
      return s.includes('## Loop Tasks (循环任务)')
        && s.includes('Require a goal')
        && s.includes('Verify each iteration')
        && s.includes('No file-count limit')
        && s.includes('Self-stop on achievement')
        && s.includes('LOOP_TASK.md');
    })()],
  ['cron skill description mentions loop triggers',
    (() => {
      const s = readFileSync(join(TARGET, '.claude/skills/cron/SKILL.md'), 'utf8');
      return s.includes('开启循环任务') && s.includes('loop task');
    })()],
  ['multi-agent-status-report.sh has pane_error_check + 403 nudge logic',
    (() => {
      const s = readFileSync(join(TARGET, 'scripts/multi-agent-status-report.sh'), 'utf8');
      return s.includes('pane_error_check()')
        && s.includes('Account is no longer a member')
        && s.includes('organization associated with this token')
        && s.includes('NUDGE_COOLDOWN_SEC=180')
        && s.includes('NUDGE_ESCALATE_SEC=300')
        && s.includes('NUDGE_TEXT="继续刚才的任务"');
    })()],
  ['multi-agent-status-report.sh persists nudges in alert.json',
    (() => {
      const s = readFileSync(join(TARGET, 'scripts/multi-agent-status-report.sh'), 'utf8');
      return s.includes('prev_nudges_json')
        && s.includes('nudges_entries')
        && s.includes('nudges:$nudges');
    })()],
  ['multi-agent-status-report.sh has 403 digest cases',
    (() => {
      const s = readFileSync(join(TARGET, 'scripts/multi-agent-status-report.sh'), 'utf8');
      return s.includes('TOKEN INVALID — manual /login required')
        && s.includes('403 detected (cooldown')
        && s.includes('auto-nudged after 403')
        && s.includes('awaiting nudge effect')
        && s.includes('403 persists after nudge');
    })()],
  ['multi-agent-status-report.sh has agent_ctx_size with pane + JSONL fallback',
    (() => {
      const s = readFileSync(join(TARGET, 'scripts/multi-agent-status-report.sh'), 'utf8');
      return s.includes('agent_ctx_size()')
        && s.includes('/clear to save')
        && s.includes('cache_read_input_tokens')
        && s.includes('"type":"assistant"');
    })()],
  ['multi-agent-status-report.sh renders 📚 context section sorted desc',
    (() => {
      const s = readFileSync(join(TARGET, 'scripts/multi-agent-status-report.sh'), 'utf8');
      return s.includes('"📚 context"')
        && s.includes('sort -rn -k1')
        && s.includes('ctx_entries+=');
    })()],
  ['multi-agent-status-report.sh empty-array safe under set -u',
    (() => {
      const s = readFileSync(join(TARGET, 'scripts/multi-agent-status-report.sh'), 'utf8');
      // Empty-array protection: ${arr[*]:-} prevents `unbound variable` when
      // nudges_entries / stuck_counts_entries are empty (no agent in 403 episode).
      return s.includes('${stuck_counts_entries[*]:-}')
        && s.includes('${nudges_entries[*]:-}');
    })()],
  ['multi-agent-status-report.sh ccusage totals tolerates non-object shape',
    (() => {
      const s = readFileSync(join(TARGET, 'scripts/multi-agent-status-report.sh'), 'utf8');
      // ccusage occasionally returns an array on top-level (no-data / error
      // cases); plain `.totals.totalCost` errors with "Cannot index array
      // with string". try/catch makes the section silently fall through.
      return s.includes('try .totals.totalCost catch 0')
        && s.includes('try .totals.totalTokens catch 0');
    })()],
  ['multi-agent-status-report.sh detects dead Telegram plugin (silent agent)',
    (() => {
      const s = readFileSync(join(TARGET, 'scripts/multi-agent-status-report.sh'), 'utf8');
      // plugin_check looks for `bun … telegram` child of the agent's claude
      // pid. If missing, claude is alive but the MCP server is dead, so the
      // agent silently drops every inbound DM until restart.
      return s.includes('plugin_check()')
        && s.includes('bun.*telegram')
        && s.includes('TG plugin dead (restart needed)');
    })()],

  // ---- Linux platform support: systemd-user templates + sync script ----
  ['systemd/cron-example.service substituted (AGENT_NAME, AGENT_DIR, no stray {{)',
    (() => {
      const p = join(TARGET, 'systemd/cron-example.service');
      if (!existsSync(p)) return false;
      const s = readFileSync(p, 'utf8');
      return s.includes(`smoke-test`) && s.includes(TARGET) && !s.includes('{{');
    })()],
  ['systemd/cron-example.service Environment=PATH includes %h/.local/bin',
    (() => {
      const p = join(TARGET, 'systemd/cron-example.service');
      if (!existsSync(p)) return false;
      return /^Environment=PATH=%h\/\.local\/bin:/m.test(readFileSync(p, 'utf8'));
    })()],
  ['systemd/cron-example.timer references prefixed service unit',
    (() => {
      const p = join(TARGET, 'systemd/cron-example.timer');
      if (!existsSync(p)) return false;
      return readFileSync(p, 'utf8').includes('Unit=hermit-smoke-test-cron-example.service');
    })()],
  ['systemd/status-reporter.service runs multi-agent-status-report.sh',
    (() => {
      const p = join(TARGET, 'systemd/status-reporter.service');
      if (!existsSync(p)) return false;
      const s = readFileSync(p, 'utf8');
      return s.includes('multi-agent-status-report.sh') && s.includes(TARGET);
    })()],
  ['systemd/status-reporter.timer fires every 10min, prefixed service ref',
    (() => {
      const p = join(TARGET, 'systemd/status-reporter.timer');
      if (!existsSync(p)) return false;
      const s = readFileSync(p, 'utf8');
      return s.includes('OnUnitActiveSec=10min') && s.includes('Unit=hermit-smoke-test-status-reporter.service');
    })()],
  ['systemd/idle-hibernator.service has HIBERNATOR_SELF env',
    (() => {
      const p = join(TARGET, 'systemd/idle-hibernator.service');
      if (!existsSync(p)) return false;
      const s = readFileSync(p, 'utf8');
      return s.includes('Environment=HIBERNATOR_SELF=smoke-test') && s.includes('idle-hibernator.sh');
    })()],
  ['systemd/idle-hibernator.timer fires every 10min',
    (() => {
      const p = join(TARGET, 'systemd/idle-hibernator.timer');
      if (!existsSync(p)) return false;
      const s = readFileSync(p, 'utf8');
      return s.includes('OnUnitActiveSec=10min') && s.includes('Unit=hermit-smoke-test-idle-hibernator.service');
    })()],
  ['systemd/wake-poller.timer fires every 60s with AccuracySec',
    (() => {
      const p = join(TARGET, 'systemd/wake-poller.timer');
      if (!existsSync(p)) return false;
      const s = readFileSync(p, 'utf8');
      return s.includes('OnUnitActiveSec=1min') && s.includes('AccuracySec') && s.includes('Unit=hermit-smoke-test-wake-poller.service');
    })()],
  ['scripts/systemd-sync.sh exists, is executable, has INSTALL/UPDATE verbs',
    (() => {
      const p = join(TARGET, 'scripts/systemd-sync.sh');
      try {
        if ((statSync(p).mode & 0o111) === 0) return false;
      } catch { return false; }
      const s = readFileSync(p, 'utf8');
      return s.includes('INSTALL') && s.includes('UPDATE') && s.includes('systemctl --user daemon-reload') && s.includes('enable --now');
    })()],
  ['scripts/systemd-sync.sh warns if lingering not enabled',
    (() => {
      const s = readFileSync(join(TARGET, 'scripts/systemd-sync.sh'), 'utf8');
      return s.includes('loginctl enable-linger') && s.includes('Linger=yes');
    })()],
];

// --- Codex flavor smoke ---
//
// Mirror the runCodexFlow walkCopy + plist rename, then assert the codex
// template lands all the expected files with substitutions in place and
// without claude-flavor artifacts (no CLAUDE.md, no .claude/, no settings.json).
if (existsSync(TARGET_CODEX)) rmSync(TARGET_CODEX, { recursive: true, force: true });

const codexVars = {
  AGENT_NAME:         'codex-smoke',
  AGENT_DISPLAY_NAME: 'Codex Smoke Test',
  PERSONA:            'automated codex-flavor smoke-test agent',
  USER_NAME:          'Tester',
  USER_TG_ID:         '9999999',
  TG_BOT_TOKEN:       '<<DUMMY_CODEX_TOKEN>>',
  BRAVE_API_KEY:      '',
  AGENT_DIR:          TARGET_CODEX,
  STATE_DIR:          TARGET_CODEX,
  CLAUDE_BIN:         '',
  HOME:               process.env.HOME || '',
};

walkCopy(TEMPLATE_CODEX_DIR, TARGET_CODEX, codexVars);

// Mirror the runCodexFlow filename-rename step for any launchd plist that
// embeds {{AGENT_NAME}} in its filename.
const codexLaunchdDir = join(TARGET_CODEX, 'launchd');
if (existsSync(codexLaunchdDir)) {
  for (const entry of readdirSync(codexLaunchdDir)) {
    if (entry.includes('{{AGENT_NAME}}')) {
      const oldPath = join(codexLaunchdDir, entry);
      const newPath = join(codexLaunchdDir, entry.replace(/\{\{AGENT_NAME\}\}/g, codexVars.AGENT_NAME));
      renameSync(oldPath, newPath);
    }
  }
}

const codexChecks = [
  ['[codex] AGENTS.md present, host-aware (Codex CLI mention)',
    (() => {
      const p = join(TARGET_CODEX, 'AGENTS.md');
      if (!existsSync(p)) return false;
      const s = readFileSync(p, 'utf8');
      return s.includes('Codex CLI') && s.includes('Codex Smoke Test') && !s.includes('{{');
    })()],
  ['[codex] No CLAUDE.md (codex flavor uses AGENTS.md as entry)',
    !existsSync(join(TARGET_CODEX, 'CLAUDE.md'))],
  ['[codex] No .claude/ subtree (codex flavor)',
    !existsSync(join(TARGET_CODEX, '.claude'))],
  ['[codex] .env substituted from .env.tmpl with token + chat_id',
    (() => {
      const p = join(TARGET_CODEX, '.env');
      if (!existsSync(p)) return false;
      const s = readFileSync(p, 'utf8');
      return s.includes('TELEGRAM_BOT_TOKEN=<<DUMMY_CODEX_TOKEN>>') && s.includes('TELEGRAM_CHAT_ID=9999999');
    })()],
  ['[codex] no leftover .env.tmpl (suffix stripped)',
    !existsSync(join(TARGET_CODEX, '.env.tmpl'))],
  ['[codex] tg-bridge.py present and has admin commands',
    (() => {
      const p = join(TARGET_CODEX, 'scripts/tg-bridge.py');
      if (!existsSync(p)) return false;
      const s = readFileSync(p, 'utf8');
      return s.includes('handle_admin') && s.includes('/help') && s.includes('/status') && s.includes('/reset') && s.includes('/restart');
    })()],
  ['[codex] tg-bridge.py supports sendPhoto for codex-generated images',
    (() => {
      const s = readFileSync(join(TARGET_CODEX, 'scripts/tg-bridge.py'), 'utf8');
      return s.includes('def send_photo')
        && s.includes('multipart/form-data')
        && s.includes('def snapshot_generated')
        && s.includes('GENERATED_DIR')
        && s.includes('.codex')
        && s.includes('generated_images')
        && s.includes('upload_photo');
    })()],
  ['[codex] tg-bridge.py + run-cron.sh both pass --dangerously-bypass-approvals-and-sandbox',
    (() => {
      const py = readFileSync(join(TARGET_CODEX, 'scripts/tg-bridge.py'), 'utf8');
      const sh = readFileSync(join(TARGET_CODEX, 'scripts/run-cron.sh'), 'utf8');
      return py.includes('--dangerously-bypass-approvals-and-sandbox')
        && sh.includes('--dangerously-bypass-approvals-and-sandbox');
    })()],
  ['[codex] tg-bridge.py uses Popen + start_new_session + killpg on timeout (30 min ceiling)',
    (() => {
      const s = readFileSync(join(TARGET_CODEX, 'scripts/tg-bridge.py'), 'utf8');
      return s.includes('subprocess.Popen')
        && s.includes('start_new_session=True')
        && s.includes('os.killpg')
        && s.includes('CODEX_TIMEOUT_SEC')
        && s.includes('1800');
    })()],
  ['[codex] hooks/{boot,pre-run,post-run}.sh present and executable',
    ['boot.sh', 'pre-run.sh', 'post-run.sh'].every(h => {
      try {
        return (statSync(join(TARGET_CODEX, 'scripts/hooks', h)).mode & 0o111) !== 0;
      } catch { return false; }
    })],
  ['[codex] safe-image.sh + with-timeout.sh + run-cron.sh executable',
    ['safe-image.sh', 'with-timeout.sh', 'run-cron.sh'].every(s => {
      try {
        return (statSync(join(TARGET_CODEX, 'scripts', s)).mode & 0o111) !== 0;
      } catch { return false; }
    })],
  ['[codex] start.sh + restart.sh use codex-<name> tmux session',
    (() => {
      const start = readFileSync(join(TARGET_CODEX, 'start.sh'), 'utf8');
      const restart = readFileSync(join(TARGET_CODEX, 'restart.sh'), 'utf8');
      return start.includes('SESSION="codex-codex-smoke"') && restart.includes('SESSION="codex-codex-smoke"');
    })()],
  ['[codex] launchd plist filename substituted from {{AGENT_NAME}} → codex-smoke',
    existsSync(join(TARGET_CODEX, 'launchd/com.codex-hermit.codex-smoke.cron-heartbeat.plist'))
    && !existsSync(join(TARGET_CODEX, 'launchd/com.codex-hermit.{{AGENT_NAME}}.cron-heartbeat.plist'))],
  ['[codex] launchd plist content has Label + AGENT_DIR substituted',
    (() => {
      const p = join(TARGET_CODEX, 'launchd/com.codex-hermit.codex-smoke.cron-heartbeat.plist');
      if (!existsSync(p)) return false;
      const s = readFileSync(p, 'utf8');
      return s.includes('com.codex-hermit.codex-smoke.cron-heartbeat')
        && s.includes(TARGET_CODEX)
        && !s.includes('{{');
    })()],
  ['[codex] AGENTS.md Mission section carries persona',
    (() => {
      const s = readFileSync(join(TARGET_CODEX, 'AGENTS.md'), 'utf8');
      return s.includes('automated codex-flavor smoke-test agent');
    })()],
  ['[codex] FIRST_RUN.md present + agent name substituted',
    (() => {
      const p = join(TARGET_CODEX, 'FIRST_RUN.md');
      if (!existsSync(p)) return false;
      const s = readFileSync(p, 'utf8');
      return s.includes('codex-smoke 上线') && !s.includes('{{');
    })()],
  ['[codex] TOOLS.md substituted USER_TG_ID',
    readFileSync(join(TARGET_CODEX, 'TOOLS.md'), 'utf8').includes('9999999')],
  ['[codex] cron/example-heartbeat.md present',
    existsSync(join(TARGET_CODEX, 'cron/example-heartbeat.md'))],
  ['[codex] skills/SKILLS.md + skills/restart + skills/provision-agent present',
    existsSync(join(TARGET_CODEX, 'scripts/skills/SKILLS.md'))
    && existsSync(join(TARGET_CODEX, 'scripts/skills/restart/SKILL.md'))
    && existsSync(join(TARGET_CODEX, 'scripts/skills/provision-agent/SKILL.md'))],
  ['[codex] multi-agent-status-report.sh executable',
    (() => {
      try { return (statSync(join(TARGET_CODEX, 'scripts/multi-agent-status-report.sh')).mode & 0o111) !== 0; }
      catch { return false; }
    })()],
];

let pass = 0, fail = 0;
for (const [label, result] of checks.concat(codexChecks)) {
  if (result) { console.log('✓', label); pass++; }
  else { console.log('✗', label); fail++; }
}
console.log('');
console.log(`Result: ${pass}/${pass+fail} passed`);
if (fail > 0) process.exit(1);
