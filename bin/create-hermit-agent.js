#!/usr/bin/env node
// create-hermit-agent — scaffold a new Telegram-connected Claude Code agent.
//
// Usage:
//   npx create-hermit-agent <name>                          Interactive prompts.
//   npx create-hermit-agent <name> --yes \
//     --bot-token <token> --user-id <chat-id> \
//     --persona "<one-line>" [--brave-key <key>]            Non-interactive.
//
// The <name> can be a plain name (placed under CWD) or a path.

import { parseArgs } from 'node:util';
import {
  existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync,
  chmodSync, statSync, symlinkSync, rmSync, renameSync,
} from 'node:fs';
import { join, resolve, dirname, basename, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir, platform } from 'node:os';
import { spawnSync, execSync } from 'node:child_process';

const prompts = (await import('prompts')).default;

const __dirname = dirname(fileURLToPath(import.meta.url));
const PACKAGE_DIR = resolve(__dirname, '..');
const TEMPLATE_DIR = join(PACKAGE_DIR, 'template');
const TEMPLATE_CODEX_DIR = join(PACKAGE_DIR, 'template-codex');
const VALID_HOSTS = ['claude', 'codex'];

const PLATFORM = platform();
const IS_DARWIN = PLATFORM === 'darwin';
const IS_LINUX = PLATFORM === 'linux';

const bold = (s) => `\x1b[1m${s}\x1b[0m`;
const red = (s) => `\x1b[31m${s}\x1b[0m`;
const green = (s) => `\x1b[32m${s}\x1b[0m`;
const yellow = (s) => `\x1b[33m${s}\x1b[0m`;
const blue = (s) => `\x1b[34m${s}\x1b[0m`;
const dim = (s) => `\x1b[2m${s}\x1b[0m`;

// Distro-aware install hint for missing prereqs. macOS users still see
// `brew install`; Linux users see the right `apt`/`dnf`/`pacman`/`apk`
// invocation for their box. Falls back to a generic hint on unknown systems.
function installHint(pkg) {
  if (IS_DARWIN) return `brew install ${pkg}`;
  if (IS_LINUX) {
    if (existsSync('/usr/bin/apt-get') || existsSync('/usr/bin/apt')) return `sudo apt install ${pkg}`;
    if (existsSync('/usr/bin/dnf')) return `sudo dnf install ${pkg}`;
    if (existsSync('/usr/bin/yum')) return `sudo yum install ${pkg}`;
    if (existsSync('/usr/bin/pacman')) return `sudo pacman -S ${pkg}`;
    if (existsSync('/sbin/apk')) return `sudo apk add ${pkg}`;
  }
  return `(use your package manager to install) ${pkg}`;
}

function die(msg) {
  console.error(red('✖ ') + msg);
  process.exit(1);
}

function step(msg) {
  console.log(blue('▸ ') + msg);
}

function ok(msg) {
  console.log(green('✓ ') + msg);
}

function warn(msg) {
  console.log(yellow('⚠ ') + msg);
}

// --- Prerequisite checks ---

function checkPrereqs(host = 'claude') {
  if (!IS_DARWIN && !IS_LINUX) {
    die(`Hermit Agent supports macOS and Linux. ${PLATFORM} is not supported (yet — PRs welcome).`);
  }

  const nodeMajor = parseInt(process.versions.node.split('.')[0], 10);
  if (nodeMajor < 18) {
    die(`Node.js 18+ required. You're on ${process.versions.node}.`);
  }

  const which = (bin) => {
    const r = spawnSync('which', [bin], { encoding: 'utf8' });
    return r.status === 0 ? r.stdout.trim() : null;
  };

  // Host-specific binary check. Codex hermits don't need the claude CLI
  // (and vice versa) — but the rest of the prereqs (tmux, curl, jq, bun on
  // claude side, python3 on codex side) overlap.
  let claude = null;
  let codex = null;
  if (host === 'claude') {
    claude = which('claude');
    if (!claude) {
      die('claude CLI not found on PATH.\n  Install it from https://docs.claude.com/claude-code, then re-run.');
    }
  } else if (host === 'codex') {
    codex = which('codex');
    if (!codex) {
      die('codex CLI not found on PATH.\n  Install it from https://developers.openai.com/codex/cli, then re-run.');
    }
    const python3 = which('python3');
    if (!python3) {
      die(`python3 not found on PATH (the codex Telegram bridge needs it).\n  Install with: ${installHint('python3')}`);
    }
  } else {
    die(`Unknown --host: ${host}. Valid: ${VALID_HOSTS.join(', ')}`);
  }

  const tmux = which('tmux');
  if (!tmux) {
    die(`tmux not found on PATH.\n  Install with: ${installHint('tmux')}`);
  }

  // curl is used both for token validation (HTTPS_PROXY-aware, see
  // validateBotToken) and the cron `-p` Bot API push path documented in
  // AGENTS.md. Treat as an explicit prereq.
  const curl = which('curl');
  if (!curl) {
    die(`curl not found on PATH.\n  Install with: ${installHint('curl')}`);
  }

  // bun is only relevant for the claude flavor (the official telegram plugin
  // ships a bun server subprocess). Codex flavor uses a Python bridge, no bun.
  // Hard prereq: a bun-less claude agent's Telegram plugin will silently fail
  // to start (claude stays alive but the bun child never spawns), which is the
  // worst kind of "looks installed but deaf" failure mode.
  let bunPath = null;
  if (host === 'claude') {
    bunPath = which('bun') || (existsSync(`${homedir()}/.bun/bin/bun`) ? `${homedir()}/.bun/bin/bun` : null);
    if (!bunPath) {
      die(`bun not found on PATH or at ~/.bun/bin/bun. The Telegram plugin's MCP server runs as a bun subprocess and will silently fail without it.\n  Install with: curl -fsSL https://bun.sh/install | bash   (then reopen your terminal)`);
    }
  }

  const jq = which('jq');
  if (!jq) {
    warn(`jq not found. Hooks and status scripts use jq. Install with: ${installHint('jq')}`);
  }

  // Linux uses systemd --user for the scheduling layer (instead of launchd).
  // Warn if the user manager isn't reachable from this shell — without it,
  // installStatusReporter() and per-agent cron timers can't be activated.
  // On a typical Linux server, this is fixed once with `loginctl enable-linger
  // $USER`; on most desktop distros it works out of the box.
  if (IS_LINUX) {
    const systemctl = which('systemctl');
    if (!systemctl) {
      warn(`systemctl not found. Hermit's Linux scheduling uses systemd --user. Install with: ${installHint('systemd')}`);
    } else {
      const r = spawnSync('systemctl', ['--user', 'show-environment'], { encoding: 'utf8' });
      if (r.status !== 0) {
        warn('systemd --user not reachable from this shell. The scheduling layer (status reporter, cron timers) will fail to install.');
        warn('On a server, run once (may need sudo): loginctl enable-linger $USER');
      }
    }
  }

  return { claude, codex, tmux, bun: bunPath, jq, host };
}

// --- Arg parsing ---

function parseCliArgs() {
  let args;
  try {
    args = parseArgs({
      allowPositionals: true,
      strict: true,
      options: {
        'bot-token':  { type: 'string' },
        'user-id':    { type: 'string' },
        'persona':    { type: 'string' },
        'brave-key':  { type: 'string' },
        'clone-of':   { type: 'string' },
        'host':       { type: 'string', default: 'claude' },
        'yes':        { type: 'boolean', short: 'y', default: false },
        'help':       { type: 'boolean', short: 'h', default: false },
      },
    });
  } catch (e) {
    die(`Invalid arguments: ${e.message}\n  Run: create-hermit-agent --help`);
  }

  if (args.values.host && !VALID_HOSTS.includes(args.values.host)) {
    die(`--host must be one of: ${VALID_HOSTS.join(', ')} (got: ${args.values.host})`);
  }

  if (args.values.help) {
    console.log(`
Usage:
  create-hermit-agent <name> [options]                Fresh agent.
  create-hermit-agent --clone-of <parent> [options]   Doppel of an existing agent.

Arguments:
  <name>                Folder name (relative to cwd) or absolute path. Omit
                        when --clone-of is used; the clone is auto-named.

Options:
  --bot-token <token>   Telegram bot token from @BotFather. Each agent (and
                        each doppel) needs its own — never reuse.
  --user-id <chat-id>   Your Telegram user/chat id (from @userinfobot).
                        In clone mode, defaults to the parent's TELEGRAM_CHAT_ID.
  --persona "<line>"    One-line description of focus. Ignored in clone mode
                        (clones inherit the parent's persona via symlinked AGENTS.md).
  --brave-key <key>     (Optional) Brave Search API key. Ignored in clone mode.
  --clone-of <parent>   Create a doppel of an existing hermit. The clone shares
                        the parent's workspace files via symlink but runs as
                        its own session with its own bot. Auto-numbered as
                        <parent>-doppel-N. <parent> can be a name (resolved as
                        a sibling of cwd) or an absolute path.
  --host <name>         Runtime host. 'claude' (default) builds a Claude Code
                        hermit with the official telegram plugin. 'codex'
                        builds a Codex CLI hermit with a Python Telegram
                        bridge daemon — uses your ChatGPT subscription
                        instead of API spend.
  --yes, -y             Skip interactive prompts (requires the above).
  --help, -h            Show this message.

Examples:
  create-hermit-agent my-agent
  create-hermit-agent my-agent -y --bot-token 123:ABC --user-id 1234567 --persona "triage my github notifications"
  create-hermit-agent my-agent --host codex -y --bot-token 123:ABC --user-id 1234567 --persona "..."
  create-hermit-agent --clone-of asst -y --bot-token 456:DEF
`);
    process.exit(0);
  }

  return args;
}

// --- Telegram ---
//
// We shell out to curl rather than using Node's built-in fetch for token
// validation:
//  1. curl honors HTTPS_PROXY / https_proxy / NO_PROXY env vars by default;
//     Node's bundled undici needs explicit ProxyAgent dispatcher setup,
//     which would cost a runtime dep. In any environment where outbound
//     HTTPS goes through an HTTP proxy, fetch silently fails to resolve
//     api.telegram.org while curl with the same env reaches it fine.
//  2. curl is already an effective prereq — the agent's cron `-p` runs use
//     it to push to the Bot API directly when MCP isn't available. We
//     promote it to an explicit prereq above and reuse it here.
//
// On non-zero exit or unparseable body we return null and let the caller
// die with the standard "Telegram rejected" message.

function validateBotToken(token) {
  const r = spawnSync('curl', [
    '-sS', '-m', '12',
    `https://api.telegram.org/bot${token}/getMe`,
  ], { encoding: 'utf8' });
  if (r.status !== 0 || !r.stdout) {
    if (r.stderr) {
      console.error(red('  curl: ') + r.stderr.trim());
    }
    return null;
  }
  try {
    const body = JSON.parse(r.stdout);
    return body.ok ? body.result : null;
  } catch {
    return null;
  }
}

// --- Interactive prompts ---

async function collectAnswers(values, positional) {
  const nameArg = positional || values['_name'];
  let name;
  if (nameArg) {
    name = nameArg;
  } else if (values.yes) {
    // Default the first-install name to `asst` for non-interactive mode.
    name = 'asst';
  } else {
    const { input } = await prompts({
      type: 'text',
      name: 'input',
      message: 'Agent name (folder)',
      initial: 'asst',
      validate: (v) => {
        if (!v) return 'Required';
        if (!/^[a-z0-9][a-z0-9_-]*$/.test(basename(v))) return 'Use lowercase letters, digits, - or _ (must start alphanumeric)';
        return true;
      },
    });
    if (!input) process.exit(1);
    name = input;
  }

  const targetDir = resolve(process.cwd(), name);
  if (existsSync(targetDir)) {
    die(`Directory already exists: ${targetDir}\n  Choose a different name or delete it first.`);
  }
  if (existsSync(dirname(targetDir)) === false) {
    die(`Parent directory does not exist: ${dirname(targetDir)}`);
  }

  let botToken = values['bot-token'];
  if (!botToken) {
    if (values.yes) die('--bot-token required with --yes');
    const r = await prompts({
      type: 'password',
      name: 'token',
      message: 'Telegram bot token (from @BotFather)',
      validate: (v) => (v && /^[0-9]+:[A-Za-z0-9_-]{30,}$/.test(v.trim())) ? true : 'Looks malformed — expected 123456789:ABCdef…',
    });
    if (!r.token) process.exit(1);
    botToken = r.token.trim();
  }
  botToken = botToken.trim();

  step('Verifying bot token against Telegram…');
  const bot = validateBotToken(botToken);
  if (!bot) {
    die('Telegram rejected the token (bot not found or network error). Check it and try again.\n  If your machine reaches the internet via an HTTP proxy, make sure HTTPS_PROXY / https_proxy is set in this shell — curl honors them automatically.');
  }
  ok(`Bot verified: @${bot.username} (${bot.first_name})`);

  let userId = values['user-id'];
  if (!userId) {
    if (values.yes) die('--user-id required with --yes');
    const r = await prompts({
      type: 'text',
      name: 'userId',
      message: 'Your Telegram user ID (message @userinfobot on Telegram to find it)',
      validate: (v) => (v && /^-?[0-9]+$/.test(v.trim())) ? true : 'Expected a numeric ID (e.g. 123456789)',
    });
    if (!r.userId) process.exit(1);
    userId = r.userId.trim();
  }
  userId = String(userId).trim();

  let persona = values.persona;
  if (!persona) {
    if (values.yes) persona = 'personal assistant';
    else {
      const r = await prompts({
        type: 'text',
        name: 'persona',
        message: 'Persona — one line, what does this agent focus on?',
        initial: 'personal assistant',
      });
      persona = (r.persona || 'personal assistant').trim();
    }
  }

  let braveKey = values['brave-key'];
  if (!braveKey && !values.yes) {
    const r = await prompts({
      type: 'text',
      name: 'braveKey',
      message: 'Brave Search API key (optional — leave blank to skip)',
      initial: '',
    });
    braveKey = (r.braveKey || '').trim();
  }
  braveKey = braveKey || '';

  const agentName = basename(targetDir);
  const displayName = agentName.replace(/[-_]/g, ' ').replace(/\b\w/g, c => c.toUpperCase());
  const stateDir = join(homedir(), '.claude', 'channels', `telegram-${agentName}`);

  return {
    agentName,
    displayName,
    persona,
    userName: bot.first_name || agentName,
    userTgId: userId,
    botToken,
    braveKey,
    targetDir,
    stateDir,
    botUsername: bot.username,
  };
}

// --- Template copy ---

// Textual files we substitute placeholders in. Binary files (images, etc.)
// are copied byte-for-byte. The list is whitelist-based to avoid mangling data.
const TEXT_EXTS = new Set([
  '.md', '.json', '.js', '.ts', '.sh', '.bash', '.zsh', '.plist',
  '.toml', '.yml', '.yaml', '.tmpl', '.gitkeep', '.gitignore',
]);

function isTextFile(path) {
  if (path.endsWith('.gitignore') || path.endsWith('.gitkeep')) return true;
  const i = path.lastIndexOf('.');
  if (i < 0) return true; // shell scripts with no extension
  const ext = path.slice(i);
  return TEXT_EXTS.has(ext);
}

function substitute(content, vars) {
  return content.replace(/\{\{(\w+)\}\}/g, (m, key) => {
    if (key in vars) return vars[key];
    return m; // leave unknown placeholders untouched
  });
}

function walkCopy(srcDir, destDir, vars) {
  if (!existsSync(destDir)) mkdirSync(destDir, { recursive: true });
  for (const entry of readdirSync(srcDir, { withFileTypes: true })) {
    const srcPath = join(srcDir, entry.name);
    let destName = entry.name;
    // Strip `.tmpl` suffix so settings.local.json.tmpl → settings.local.json
    if (destName.endsWith('.tmpl')) destName = destName.slice(0, -5);

    const destPath = join(destDir, destName);
    if (entry.isDirectory()) {
      walkCopy(srcPath, destPath, vars);
    } else if (entry.isFile()) {
      if (isTextFile(srcPath)) {
        const raw = readFileSync(srcPath, 'utf8');
        writeFileSync(destPath, substitute(raw, vars));
      } else {
        // Binary: copy as-is
        writeFileSync(destPath, readFileSync(srcPath));
      }
      // Preserve executable bit for scripts
      try {
        const mode = statSync(srcPath).mode;
        chmodSync(destPath, mode);
      } catch {}
    }
  }
}

function makeExecutable(filePath) {
  try { chmodSync(filePath, 0o755); } catch {}
}

// --- Plugin install ---

function installTelegramPlugin(claudeBin, targetDir) {
  step('Installing telegram plugin at project scope…');
  const r = spawnSync(claudeBin, ['plugin', 'install', 'telegram@claude-plugins-official', '-s', 'project'], {
    cwd: targetDir,
    stdio: 'inherit',
  });
  if (r.status !== 0) {
    die(`claude plugin install failed with exit code ${r.status}. Inspect the output above and re-run.`);
  }
  ok('Telegram plugin registered.');
}

// --- State dir + .env ---

function writeStateDir(stateDir, botToken, userId) {
  step(`Writing state dir: ${stateDir}`);
  mkdirSync(stateDir, { recursive: true, mode: 0o700 });

  // Plugin .env: bot token + (if set) the current shell's HTTP proxy vars.
  // Claude Code drops HTTPS_PROXY / HTTP_PROXY / NO_PROXY from the env it
  // hands to spawned plugin subprocesses (ALL_PROXY survives, but bun's
  // fetch doesn't consume SOCKS-shaped ALL_PROXY). Without this the plugin's
  // bun process can't long-poll Telegram on machines that need a proxy.
  // server.ts reads .env with a "real env wins" precedence, so this is a
  // safety net — if the user explicitly sets these in the runtime env, those
  // win. We persist whatever lowercased / uppercased forms we see.
  const envPath = join(stateDir, '.env');
  let envContent = `TELEGRAM_BOT_TOKEN=${botToken}\n`;
  for (const k of ['HTTPS_PROXY', 'HTTP_PROXY', 'NO_PROXY',
                   'https_proxy', 'http_proxy', 'no_proxy']) {
    const v = process.env[k];
    if (v) envContent += `${k}=${v}\n`;
  }
  writeFileSync(envPath, envContent, { mode: 0o600 });
  chmodSync(envPath, 0o600);
  ok(`.env written at ${envPath} (mode 600)`);

  // Pre-populate access.json so the user's own DMs are allowed from message 1.
  // Without this, the plugin defaults to pairing mode and the first DM replies
  // with a 6-char code that the user would have to approve inside the claude
  // REPL with /telegram:access pair <code> — painful first-run UX.
  // dmPolicy stays "pairing" so strangers who find the bot's @handle still get
  // the pairing flow rather than silent delivery.
  const accessPath = join(stateDir, 'access.json');
  const access = {
    dmPolicy: 'pairing',
    allowFrom: [String(userId)],
    groups: {},
    pending: {},
  };
  writeFileSync(accessPath, JSON.stringify(access, null, 2) + '\n', { mode: 0o600 });
  chmodSync(accessPath, 0o600);
  ok(`access.json written (user ${userId} pre-allowed, no pairing step needed)`);
}

// --- npm install for playwright ---

function npmInstall(targetDir) {
  step('Running npm install (for playwright browser-automation)…');
  const r = spawnSync('npm', ['install', '--no-audit', '--no-fund', '--silent'], {
    cwd: targetDir,
    stdio: 'inherit',
  });
  if (r.status !== 0) {
    warn(`npm install exited ${r.status}. Browser automation may not work until you re-run 'npm install' in ${targetDir}.`);
  } else {
    ok('npm install complete.');
  }
}

// --- Pre-acknowledge first-run dialogs ---
//
// Claude Code raises two blocking TUI dialogs on a fresh Mac:
//   1) "Do you trust this folder?"         (per-project, first time in each dir)
//   2) "Allow dangerously-skip-permissions warning?"  (user-scope, once ever)
//
// Both block startup inside the tmux pane. Since the agent is headless and the
// user is interacting via Telegram, nobody is there to press Enter — the bot
// appears dead. We pre-acknowledge both by writing the persistence keys Claude
// Code would have written itself after the user confirmed.
//
// The key names were confirmed against the shipped claude binary
// (v2.1.117) — binary includes a migration routine (iAK) that moves legacy
// bypassPermissionsModeAccepted → settings.json skipDangerousModePermissionPrompt.
// We write the current-canonical name directly.

function preAcknowledgeClaudeDialogs(targetDir) {
  step('Pre-acknowledging first-run Claude Code dialogs…');

  // 1. User-scope: skipDangerousModePermissionPrompt.
  //    Lives in ~/.claude/settings.json. Set once, applies to all claude runs.
  const userSettingsPath = join(homedir(), '.claude', 'settings.json');
  try {
    mkdirSync(dirname(userSettingsPath), { recursive: true });
    let s = {};
    if (existsSync(userSettingsPath)) {
      s = JSON.parse(readFileSync(userSettingsPath, 'utf8'));
    }
    if (!s.skipDangerousModePermissionPrompt) {
      s.skipDangerousModePermissionPrompt = true;
      writeFileSync(userSettingsPath, JSON.stringify(s, null, 2) + '\n');
      ok('  ~/.claude/settings.json: set skipDangerousModePermissionPrompt=true');
    } else {
      ok('  ~/.claude/settings.json: skipDangerousModePermissionPrompt already set');
    }
  } catch (e) {
    warn(`  Could not update ~/.claude/settings.json: ${e.message}. First start may hit the dangerous-mode warning; press Enter to dismiss.`);
  }

  // 2. Per-project: hasTrustDialogAccepted + hasCompletedProjectOnboarding.
  //    Lives in ~/.claude.json under .projects[<abs-path>].
  const claudeJsonPath = join(homedir(), '.claude.json');
  try {
    let cfg = {};
    if (existsSync(claudeJsonPath)) {
      cfg = JSON.parse(readFileSync(claudeJsonPath, 'utf8'));
    }
    cfg.projects = cfg.projects || {};
    cfg.projects[targetDir] = {
      ...(cfg.projects[targetDir] || {}),
      hasTrustDialogAccepted: true,
      hasCompletedProjectOnboarding: true,
    };
    writeFileSync(claudeJsonPath, JSON.stringify(cfg, null, 2) + '\n');
    ok(`  ~/.claude.json: trust + onboarding accepted for ${targetDir}`);
  } catch (e) {
    warn(`  Could not update ~/.claude.json: ${e.message}. First start may hit the trust-folder dialog; press Enter to dismiss.`);
  }
}

// --- Multi-agent status reporter ---
//
// One-per-host: the FIRST hermit installed on a machine wires this up and
// becomes the status coordinator (pushes a 🟢/🟨/🟥/⚫ digest every 10 min).
// Subsequent hermits detect the existing job and skip — otherwise every
// agent would fire its own digest and flood Telegram.
//
// macOS uses launchd (LaunchAgent plist in ~/Library/LaunchAgents/).
// Linux uses systemd --user (.service + .timer in ~/.config/systemd/user/).

// Returns one of:
//   { role: 'master', coordinator: <agentName> }     installed status-reporter
//   { role: 'worker', coordinator: <other-name> }    skipped — coordinator exists
//   { role: 'worker', coordinator: null }            skipped — files missing or activation failed
function installStatusReporter(targetDir, agentName) {
  if (IS_DARWIN) return installStatusReporterDarwin(targetDir, agentName);
  if (IS_LINUX) return installStatusReporterLinux(targetDir, agentName);
  return { role: 'worker', coordinator: null };
}

function installStatusReporterDarwin(targetDir, agentName) {
  step('Installing multi-agent status reporter LaunchAgent…');

  const launchAgentsDir = join(homedir(), 'Library', 'LaunchAgents');
  mkdirSync(launchAgentsDir, { recursive: true });

  // Detect an existing hermit-agent status reporter (installed by a sibling).
  let existing = [];
  try {
    existing = readdirSync(launchAgentsDir)
      .filter((f) => /^com\.hermit-agent\..+\.status-reporter\.plist$/.test(f));
  } catch {
    existing = [];
  }
  if (existing.length > 0) {
    const m = existing[0].match(/^com\.hermit-agent\.(.+)\.status-reporter\.plist$/);
    const coordinator = m ? m[1] : null;
    ok(`Status reporter already installed by ${coordinator || 'a sibling'} — this hermit will be a worker (the master is ${coordinator}).`);
    return { role: 'worker', coordinator };
  }

  const srcPlist = join(targetDir, 'launchd', 'status-reporter.plist');
  if (!existsSync(srcPlist)) {
    warn(`launchd/status-reporter.plist missing from scaffold — skipping LaunchAgent install.`);
    return { role: 'worker', coordinator: null };
  }

  // The coordinator writes a log; make sure its parent dir exists so launchd
  // doesn't error on first fire.
  try { mkdirSync(join(targetDir, '.claude', 'state'), { recursive: true }); } catch {}

  const destPlist = join(launchAgentsDir, `com.hermit-agent.${agentName}.status-reporter.plist`);
  try {
    writeFileSync(destPlist, readFileSync(srcPlist));
    chmodSync(destPlist, 0o644);
  } catch (e) {
    warn(`Could not copy plist to ${destPlist}: ${e.message}\n  Install manually later: cp ${srcPlist} ${destPlist} && launchctl load ${destPlist}`);
    return { role: 'worker', coordinator: null };
  }

  const r = spawnSync('launchctl', ['load', destPlist], {
    stdio: ['ignore', 'pipe', 'pipe'],
    encoding: 'utf8',
  });
  if (r.status !== 0) {
    warn(`launchctl load exited ${r.status}. Output: ${(r.stderr || r.stdout || '').trim()}`);
    warn(`You can retry manually: launchctl load ${destPlist}`);
    return { role: 'worker', coordinator: null };
  }
  ok(`Status reporter loaded — ${agentName} is this machine's MASTER (the coordinator). Cadence: 10 min.`);
  return { role: 'master', coordinator: agentName };
}

function installStatusReporterLinux(targetDir, agentName) {
  step('Installing multi-agent status reporter (systemd --user timer)…');

  const unitDir = process.env.XDG_CONFIG_HOME
    ? join(process.env.XDG_CONFIG_HOME, 'systemd', 'user')
    : join(homedir(), '.config', 'systemd', 'user');
  mkdirSync(unitDir, { recursive: true });

  // Detect an existing hermit-agent status reporter (installed by a sibling).
  let existing = [];
  try {
    existing = readdirSync(unitDir)
      .filter((f) => /^hermit-.+-status-reporter\.timer$/.test(f));
  } catch {
    existing = [];
  }
  if (existing.length > 0) {
    const m = existing[0].match(/^hermit-(.+)-status-reporter\.timer$/);
    const coordinator = m ? m[1] : null;
    ok(`Status reporter already installed by ${coordinator || 'a sibling'} — this hermit will be a worker (the master is ${coordinator}).`);
    return { role: 'worker', coordinator };
  }

  const srcService = join(targetDir, 'systemd', 'status-reporter.service');
  const srcTimer = join(targetDir, 'systemd', 'status-reporter.timer');
  if (!existsSync(srcService) || !existsSync(srcTimer)) {
    warn(`systemd/status-reporter.{service,timer} missing from scaffold — skipping coordinator install.`);
    return { role: 'worker', coordinator: null };
  }

  // The coordinator's script writes alert state under .claude/state/. Make
  // sure the dir exists so the first fire doesn't error on a missing path.
  try { mkdirSync(join(targetDir, '.claude', 'state'), { recursive: true }); } catch {}

  const timerName = `hermit-${agentName}-status-reporter.timer`;
  const serviceName = `hermit-${agentName}-status-reporter.service`;
  const destService = join(unitDir, serviceName);
  const destTimer = join(unitDir, timerName);
  const manualHint = `Install manually: cp ${srcService} ${destService} && cp ${srcTimer} ${destTimer} && systemctl --user daemon-reload && systemctl --user enable --now ${timerName}`;

  try {
    writeFileSync(destService, readFileSync(srcService));
    writeFileSync(destTimer, readFileSync(srcTimer));
    chmodSync(destService, 0o644);
    chmodSync(destTimer, 0o644);
  } catch (e) {
    warn(`Could not copy systemd units: ${e.message}\n  ${manualHint}`);
    return { role: 'worker', coordinator: null };
  }

  let r = spawnSync('systemctl', ['--user', 'daemon-reload'], {
    stdio: ['ignore', 'pipe', 'pipe'],
    encoding: 'utf8',
  });
  if (r.status !== 0) {
    warn(`systemctl --user daemon-reload exited ${r.status}. Output: ${(r.stderr || r.stdout || '').trim()}`);
    warn(`Retry manually: systemctl --user daemon-reload && systemctl --user enable --now ${timerName}`);
    return { role: 'worker', coordinator: null };
  }

  r = spawnSync('systemctl', ['--user', 'enable', '--now', timerName], {
    stdio: ['ignore', 'pipe', 'pipe'],
    encoding: 'utf8',
  });
  if (r.status !== 0) {
    warn(`systemctl --user enable --now ${timerName} exited ${r.status}. Output: ${(r.stderr || r.stdout || '').trim()}`);
    warn(`Retry manually: systemctl --user enable --now ${timerName}`);
    return { role: 'worker', coordinator: null };
  }

  // Linger sanity check — without it, the timer dies on logout (server gotcha).
  const linger = spawnSync('loginctl', ['show-user', process.env.USER || ''], {
    stdio: ['ignore', 'pipe', 'pipe'],
    encoding: 'utf8',
  });
  if (linger.status === 0 && !/^Linger=yes$/m.test(linger.stdout || '')) {
    warn(`Lingering not enabled for $USER — systemd --user services will stop when you log out.`);
    warn(`Run once (may need sudo): loginctl enable-linger ${process.env.USER}`);
  }

  ok(`Status reporter loaded — ${agentName} is this machine's MASTER (the coordinator). Cadence: 10 min.`);
  return { role: 'master', coordinator: agentName };
}

// --- Hibernation system (idle-hibernator + wake-poller) ---
//
// Installed only on the master/coordinator hermit, alongside the status reporter.
// Workers skip — the master runs the fleet-wide hibernation sweep and wake poll.
// Single-hermit users still get the LaunchAgents loaded, but the scripts no-op
// quickly (idle-hibernator excludes the master self; wake-poller's fast-path
// exits in <100ms when nothing is paused).

const HIBERNATION_TASKS = ['idle-hibernator', 'wake-poller'];

function installHibernationSystem(targetDir, agentName, role) {
  if (role !== 'master') return { installed: [], failed: [] };
  if (IS_DARWIN) return installHibernationSystemDarwin(targetDir, agentName);
  if (IS_LINUX) return installHibernationSystemLinux(targetDir, agentName);
  return { installed: [], failed: [] };
}

function installHibernationSystemDarwin(targetDir, agentName) {
  step('Installing hibernation LaunchAgents (idle-hibernator + wake-poller)…');

  const launchAgentsDir = join(homedir(), 'Library', 'LaunchAgents');
  mkdirSync(launchAgentsDir, { recursive: true });

  const installed = [];
  const failed = [];

  for (const task of HIBERNATION_TASKS) {
    const srcPlist = join(targetDir, 'launchd', `${task}.plist`);
    if (!existsSync(srcPlist)) {
      warn(`launchd/${task}.plist missing from scaffold — skipping.`);
      failed.push(task);
      continue;
    }
    const destPlist = join(launchAgentsDir, `com.hermit-agent.${agentName}.${task}.plist`);
    try {
      writeFileSync(destPlist, readFileSync(srcPlist));
      chmodSync(destPlist, 0o644);
    } catch (e) {
      warn(`Could not copy ${task} plist: ${e.message}\n  Install manually: cp ${srcPlist} ${destPlist} && launchctl load ${destPlist}`);
      failed.push(task);
      continue;
    }
    const r = spawnSync('launchctl', ['load', destPlist], {
      stdio: ['ignore', 'pipe', 'pipe'],
      encoding: 'utf8',
    });
    if (r.status !== 0) {
      warn(`launchctl load ${task} exited ${r.status}. Output: ${(r.stderr || r.stdout || '').trim()}`);
      warn(`Retry manually: launchctl load ${destPlist}`);
      failed.push(task);
      continue;
    }
    installed.push(task);
  }

  if (installed.length > 0) {
    ok(`Hibernation LaunchAgents loaded: ${installed.join(' + ')}. Idle threshold: 48h.`);
  }
  return { installed, failed };
}

function installHibernationSystemLinux(targetDir, agentName) {
  step('Installing hibernation systemd timers (idle-hibernator + wake-poller)…');

  const unitDir = process.env.XDG_CONFIG_HOME
    ? join(process.env.XDG_CONFIG_HOME, 'systemd', 'user')
    : join(homedir(), '.config', 'systemd', 'user');
  mkdirSync(unitDir, { recursive: true });

  const installed = [];
  const failed = [];

  for (const task of HIBERNATION_TASKS) {
    const srcService = join(targetDir, 'systemd', `${task}.service`);
    const srcTimer = join(targetDir, 'systemd', `${task}.timer`);
    if (!existsSync(srcService) || !existsSync(srcTimer)) {
      warn(`systemd/${task}.{service,timer} missing — skipping.`);
      failed.push(task);
      continue;
    }
    const timerName = `hermit-${agentName}-${task}.timer`;
    const serviceName = `hermit-${agentName}-${task}.service`;
    const destService = join(unitDir, serviceName);
    const destTimer = join(unitDir, timerName);
    try {
      writeFileSync(destService, readFileSync(srcService));
      writeFileSync(destTimer, readFileSync(srcTimer));
      chmodSync(destService, 0o644);
      chmodSync(destTimer, 0o644);
    } catch (e) {
      warn(`Could not copy ${task} units: ${e.message}`);
      failed.push(task);
      continue;
    }
    const r = spawnSync('systemctl', ['--user', 'enable', '--now', timerName], {
      stdio: ['ignore', 'pipe', 'pipe'],
      encoding: 'utf8',
    });
    if (r.status !== 0) {
      warn(`systemctl --user enable --now ${timerName} exited ${r.status}. Output: ${(r.stderr || r.stdout || '').trim()}`);
      warn(`Retry manually: systemctl --user daemon-reload && systemctl --user enable --now ${timerName}`);
      failed.push(task);
      continue;
    }
    installed.push(task);
  }

  // One daemon-reload covers both unit pairs.
  if (installed.length > 0) {
    spawnSync('systemctl', ['--user', 'daemon-reload'], { stdio: 'ignore' });
    ok(`Hibernation systemd timers loaded: ${installed.join(' + ')}. Idle threshold: 48h.`);
  }
  return { installed, failed };
}

// --- Dead-session reaper (master-only daily sweep) ---
//
// Daily at 04:10 — scans every sibling agent's ~/.claude/projects/<enc>/
// directory and ships JSONLs (+ sidecar subdirs) older than REAP_AGE_DAYS
// to the OS recycle bin. Active sessions and hibernated wake targets are
// double-protected via session-status.json + paused.json. See the script's
// header comment for the full reap policy.
//
// Master-only for the same reason as hibernation: single fleet-wide sweep,
// not duplicated per worker.

function installDeadSessionReaper(targetDir, agentName, role) {
  if (role !== 'master') return { installed: false, failed: false };
  if (IS_DARWIN) return installDeadSessionReaperDarwin(targetDir, agentName);
  if (IS_LINUX) return installDeadSessionReaperLinux(targetDir, agentName);
  return { installed: false, failed: false };
}

function installDeadSessionReaperDarwin(targetDir, agentName) {
  step('Installing dead-session reaper LaunchAgent (daily 04:10)…');
  const launchAgentsDir = join(homedir(), 'Library', 'LaunchAgents');
  mkdirSync(launchAgentsDir, { recursive: true });

  const srcPlist = join(targetDir, 'launchd', 'reap-dead-sessions.plist');
  if (!existsSync(srcPlist)) {
    warn('launchd/reap-dead-sessions.plist missing from scaffold — skipping.');
    return { installed: false, failed: true };
  }
  const destPlist = join(launchAgentsDir, `com.hermit-agent.${agentName}.reap-dead-sessions.plist`);
  try {
    writeFileSync(destPlist, readFileSync(srcPlist));
    chmodSync(destPlist, 0o644);
  } catch (e) {
    warn(`Could not copy reap-dead-sessions plist: ${e.message}\n  Install manually: cp ${srcPlist} ${destPlist} && launchctl load ${destPlist}`);
    return { installed: false, failed: true };
  }
  const r = spawnSync('launchctl', ['load', destPlist], {
    stdio: ['ignore', 'pipe', 'pipe'],
    encoding: 'utf8',
  });
  if (r.status !== 0) {
    warn(`launchctl load reap-dead-sessions exited ${r.status}. Output: ${(r.stderr || r.stdout || '').trim()}`);
    warn(`Retry manually: launchctl load ${destPlist}`);
    return { installed: false, failed: true };
  }
  ok('Dead-session reaper LaunchAgent loaded. Sweeps daily at 04:10, 3-day buffer.');
  return { installed: true, failed: false };
}

function installDeadSessionReaperLinux(targetDir, agentName) {
  step('Installing dead-session reaper systemd timer (daily 04:10)…');
  const unitDir = process.env.XDG_CONFIG_HOME
    ? join(process.env.XDG_CONFIG_HOME, 'systemd', 'user')
    : join(homedir(), '.config', 'systemd', 'user');
  mkdirSync(unitDir, { recursive: true });

  const srcService = join(targetDir, 'systemd', 'reap-dead-sessions.service');
  const srcTimer = join(targetDir, 'systemd', 'reap-dead-sessions.timer');
  if (!existsSync(srcService) || !existsSync(srcTimer)) {
    warn('systemd/reap-dead-sessions.{service,timer} missing — skipping.');
    return { installed: false, failed: true };
  }
  const timerName = `hermit-${agentName}-reap-dead-sessions.timer`;
  const serviceName = `hermit-${agentName}-reap-dead-sessions.service`;
  const destService = join(unitDir, serviceName);
  const destTimer = join(unitDir, timerName);
  try {
    writeFileSync(destService, readFileSync(srcService));
    writeFileSync(destTimer, readFileSync(srcTimer));
    chmodSync(destService, 0o644);
    chmodSync(destTimer, 0o644);
  } catch (e) {
    warn(`Could not copy reap-dead-sessions units: ${e.message}`);
    return { installed: false, failed: true };
  }
  const r = spawnSync('systemctl', ['--user', 'enable', '--now', timerName], {
    stdio: ['ignore', 'pipe', 'pipe'],
    encoding: 'utf8',
  });
  if (r.status !== 0) {
    warn(`systemctl --user enable --now ${timerName} exited ${r.status}. Output: ${(r.stderr || r.stdout || '').trim()}`);
    warn(`Retry manually: systemctl --user daemon-reload && systemctl --user enable --now ${timerName}`);
    return { installed: false, failed: true };
  }
  spawnSync('systemctl', ['--user', 'daemon-reload'], { stdio: 'ignore' });
  ok('Dead-session reaper systemd timer loaded. Sweeps daily at 04:10, 3-day buffer.');
  return { installed: true, failed: false };
}

// --- Per-platform layer pruning ---
//
// The template ships everything: launchd + systemd templates, browser /
// image safety scripts, all hooks. After walkCopy() we strip what doesn't
// apply to the current platform.
//
//   macOS: drop systemd-user templates + sync script. macOS scaffold keeps
//          full feature set (browser, image safety, launchd scheduling).
//   Linux: drop launchd templates + sync script (use systemd-user instead).
//          ALSO drop the browser layer (chrome-launcher, browser-lock,
//          playwright-mcp-launcher, scripts/browser/, browser-automation
//          skill) and the image-safety layer (safe-image.sh,
//          pre-read-image.sh hook). These are macOS-shaped (sips, .app
//          paths) and porting them is out of scope for this PR — Linux
//          gets a deliberately reduced surface for v1. Follow-up PRs can
//          add cross-platform versions if there's demand.
//
// JSON tweaks for the Linux scaffold (post-walkCopy):
//   .claude/settings.json: remove playwright MCP server + mcp__playwright*
//                          allow entries.
//   .claude/settings.local.json: drop the PreToolUse Read matcher that
//                                fires the pre-read-image hook.
function prunePlatformLayers(targetDir) {
  const trash = (rel, isDir) => {
    const abs = join(targetDir, rel);
    if (existsSync(abs)) rmSync(abs, { recursive: !!isDir, force: true });
  };

  if (IS_DARWIN) {
    trash('systemd', true);
    trash('scripts/systemd-sync.sh', false);
    return;
  }

  if (!IS_LINUX) return;

  // Scheduling: drop launchd, keep systemd
  trash('launchd', true);
  trash('scripts/launchd-sync.sh', false);

  // Image safety layer (macOS sips-shaped)
  trash('scripts/safe-image.sh', false);
  trash('scripts/hooks/pre-read-image.sh', false);

  // Browser layer (macOS .app paths, Playwright MCP)
  trash('scripts/chrome-launcher.sh', false);
  trash('scripts/browser-lock.sh', false);
  trash('scripts/playwright-mcp-launcher.sh', false);
  trash('scripts/browser', true);
  trash('.claude/skills/browser-automation', true);

  // settings.json: drop playwright MCP server + mcp__playwright* perms
  const settingsPath = join(targetDir, '.claude', 'settings.json');
  if (existsSync(settingsPath)) {
    try {
      const s = JSON.parse(readFileSync(settingsPath, 'utf8'));
      if (s.mcpServers) {
        delete s.mcpServers['playwright-browser'];
        if (Object.keys(s.mcpServers).length === 0) delete s.mcpServers;
      }
      if (Array.isArray(s.permissions?.allow)) {
        s.permissions.allow = s.permissions.allow.filter(
          (p) => !/^mcp__playwright/.test(p),
        );
      }
      writeFileSync(settingsPath, JSON.stringify(s, null, 2) + '\n');
    } catch (e) {
      warn(`Could not strip playwright MCP entries from ${settingsPath}: ${e.message}`);
    }
  }

  // settings.local.json: drop the PreToolUse Read-matcher entry that fires
  // pre-read-image.sh
  const localSettingsPath = join(targetDir, '.claude', 'settings.local.json');
  if (existsSync(localSettingsPath)) {
    try {
      const s = JSON.parse(readFileSync(localSettingsPath, 'utf8'));
      const pre = s.hooks?.PreToolUse;
      if (Array.isArray(pre)) {
        s.hooks.PreToolUse = pre.filter((entry) =>
          !entry.hooks?.some((h) => h.command && h.command.includes('pre-read-image.sh')),
        );
      }
      writeFileSync(localSettingsPath, JSON.stringify(s, null, 2) + '\n');
    } catch (e) {
      warn(`Could not strip pre-read-image hook from ${localSettingsPath}: ${e.message}`);
    }
  }

  // package.json: drop playwright dep (only used by the browser layer we
  // just pruned). Without this strip + the npmInstall skip in main(), a
  // Linux scaffold pulls 15 MB of playwright into node_modules for nothing.
  const pkgPath = join(targetDir, 'package.json');
  if (existsSync(pkgPath)) {
    try {
      const p = JSON.parse(readFileSync(pkgPath, 'utf8'));
      if (p.dependencies) {
        delete p.dependencies.playwright;
        if (Object.keys(p.dependencies).length === 0) delete p.dependencies;
      }
      writeFileSync(pkgPath, JSON.stringify(p, null, 2) + '\n');
    } catch (e) {
      warn(`Could not strip playwright from ${pkgPath}: ${e.message}`);
    }
  }
}

// --- Clone (doppel) flow ---
//
// A doppel shares the parent agent's workspace files via symlinks (SOUL.md,
// AGENTS.md, MEMORY.md, src/, scripts/, etc.) but runs as its own Claude Code
// session, has its own bot, its own tmux pane, its own .claude/state. Used
// when the user wants a parallel viewpoint on the same project.

function resolveCloneParent(arg) {
  // Accept either a name (resolved as sibling of cwd) or an absolute path.
  const candidate = arg.startsWith('/')
    ? arg
    : resolve(process.cwd(), arg.includes('/') ? arg : `../${arg}`);

  if (!existsSync(candidate)) {
    die(`Parent agent not found at ${candidate}.\n  Pass --clone-of <name> for a sibling of cwd, or an absolute path.`);
  }
  if (!existsSync(join(candidate, 'CLAUDE.md'))) {
    die(`${candidate} does not look like a hermit agent (no CLAUDE.md).`);
  }
  return candidate;
}

function nextDoppelNumber(parentDir) {
  // Existing doppels of this parent live next to it as <basename>-doppel-N.
  const parentBase = basename(parentDir);
  const siblingDir = dirname(parentDir);
  let max = 0;
  try {
    for (const entry of readdirSync(siblingDir)) {
      const m = entry.match(new RegExp(`^${parentBase}-doppel-(\\d+)$`));
      if (m) {
        const n = parseInt(m[1], 10);
        if (n > max) max = n;
      }
    }
  } catch {}
  return max + 1;
}

function readParentChatId(parentDir) {
  // Try to read TELEGRAM_CHAT_ID out of the parent's settings.local.json so
  // the user can omit --user-id in clone mode (most clones go to the same chat).
  try {
    const raw = readFileSync(join(parentDir, '.claude', 'settings.local.json'), 'utf8');
    const cfg = JSON.parse(raw);
    return cfg?.env?.TELEGRAM_CHAT_ID || null;
  } catch {
    return null;
  }
}

function symlinkIfExists(parentDir, cloneDir, rel, parentBaseName) {
  // Build the relative symlink target so the link survives moves of the
  // whole tree. From cloneDir/<rel> the target is ../<parentBase>/<rel>.
  const src = join(parentDir, rel);
  if (!existsSync(src)) return;
  const dest = join(cloneDir, rel);
  // Make sure the destination's parent dir exists (for nested rel like .claude/skills).
  mkdirSync(dirname(dest), { recursive: true });
  // Compute the relative target depth: every '/' in rel adds one '../'.
  const depth = rel.split('/').length;
  const upDots = '../'.repeat(depth);
  const target = `${upDots}${parentBaseName}/${rel}`;
  symlinkSync(target, dest);
}

async function collectCloneAnswers(values, parentDir) {
  const parentBase = basename(parentDir);
  const siblingDir = dirname(parentDir);
  const n = nextDoppelNumber(parentDir);
  const cloneName = `${parentBase}-doppel-${n}`;
  const cloneDir = join(siblingDir, cloneName);

  if (existsSync(cloneDir)) {
    die(`Computed clone path already exists: ${cloneDir}\n  Should never happen unless something raced. Delete it or pick a higher N manually.`);
  }

  // Bot token (required, prompt if missing).
  let botToken = values['bot-token'];
  if (!botToken) {
    if (values.yes) die('--bot-token required with --yes');
    const r = await prompts({
      type: 'password',
      name: 'token',
      message: `Telegram bot token for the new doppel (separate bot from ${parentBase}'s)`,
      validate: (v) => (v && /^[0-9]+:[A-Za-z0-9_-]{30,}$/.test(v.trim())) ? true : 'Looks malformed — expected 123456789:ABCdef…',
    });
    if (!r.token) process.exit(1);
    botToken = r.token.trim();
  }
  botToken = botToken.trim();

  step('Verifying bot token against Telegram…');
  const bot = validateBotToken(botToken);
  if (!bot) {
    die('Telegram rejected the token (bot not found or network error). Check it and try again.\n  If your machine reaches the internet via an HTTP proxy, make sure HTTPS_PROXY / https_proxy is set in this shell — curl honors them automatically.');
  }
  ok(`Bot verified: @${bot.username} (${bot.first_name})`);

  // User chat id (defaults to parent's TELEGRAM_CHAT_ID).
  let userId = values['user-id'];
  if (!userId) {
    const inherited = readParentChatId(parentDir);
    if (inherited) {
      userId = inherited;
      ok(`Using parent's TELEGRAM_CHAT_ID: ${userId}`);
    } else if (values.yes) {
      die('--user-id required (parent has no TELEGRAM_CHAT_ID to inherit)');
    } else {
      const r = await prompts({
        type: 'text',
        name: 'userId',
        message: 'Your Telegram user ID',
        validate: (v) => (v && /^-?[0-9]+$/.test(v.trim())) ? true : 'Expected a numeric ID (e.g. 123456789)',
      });
      if (!r.userId) process.exit(1);
      userId = r.userId.trim();
    }
  }
  userId = String(userId).trim();

  const stateDir = join(homedir(), '.claude', 'channels', `telegram-${cloneName}`);

  return {
    parentDir,
    parentBase,
    cloneName,
    cloneDir,
    n,
    botToken,
    botUsername: bot.username,
    userTgId: userId,
    stateDir,
  };
}

function writeCloneRealFiles(c, claudeBin) {
  const today = new Date().toISOString().slice(0, 10);

  // IDENTITY.md — clone identity, overrides the parent's via real-file precedence.
  writeFileSync(join(c.cloneDir, 'IDENTITY.md'), `# IDENTITY.md - Who Am I?

- **Name:** ${c.cloneName}
- **Origin:** I'm a doppel (复制体) of \`${c.parentBase}\`. We share the same workspace files (SOUL/USER/AGENTS/TOOLS/MEMORY are symlinks to ../${c.parentBase}/), but our Claude Code sessions are separate and we route through different Telegram bots.
- **Vibe:** Same project context as ${c.parentBase}, fresh perspective on the same files.
- **Avatar:**

---

I greet via my own Telegram bot — ${c.parentBase} does not see my conversations and I do not see theirs.

Per-clone files (real, not symlinks): this IDENTITY.md, BOOTSTRAP.md, HEARTBEAT.md, .claude/settings.local.json + state/.

Daily log convention: I write to \`memory/${today}-doppel-${c.n}.md\` (note the suffix). ${c.parentBase} writes to \`memory/${today}.md\` (no suffix). We can read each other's logs.

Shared memory write discipline: see BOOTSTRAP.md.
`);

  // BOOTSTRAP.md — first-run discipline, deleted by AGENTS.md rule after first turn.
  writeFileSync(join(c.cloneDir, 'BOOTSTRAP.md'), `# BOOTSTRAP.md - First Run

You are a doppel — a clone of the parent agent \`${c.parentBase}\`. You share the parent's workspace via symlinks but run as your own session with your own Telegram bot.

## Shared vs per-clone

**Symlinked from \`../${c.parentBase}/\` (read-shared):**
- CLAUDE.md, SOUL.md, USER.md, AGENTS.md, TOOLS.md, MEMORY.md
- memory/ (daily logs dir)
- scripts/, .claude/skills/, browser/, node_modules/

**Per-clone real files (yours alone):**
- IDENTITY.md (your clone identity)
- HEARTBEAT.md (your task list)
- .claude/settings.json, .claude/settings.local.json, .claude/state/
- restart.sh, agent.pid

## Long-term memory — write discipline

\`MEMORY.md\` is symlinked to \`../${c.parentBase}/MEMORY.md\`. The parent writes to it; other doppels of \`${c.parentBase}\` may also write to it. There is **no atomic locking**, so concurrent appends from multiple sessions can lose writes.

Default rule: **MEMORY.md is read-only for you.**

If you discover something genuinely worth long-term memory:
1. **Prefer**: write only to your daily log \`memory/YYYY-MM-DD-doppel-${c.n}.md\`. The parent and other doppels can read it.
2. **If you must update MEMORY.md**: \`cat\` the latest version right before editing (don't trust any earlier read), make the smallest possible append, save. Keep the read→write window short.
3. **Never** restructure or rewrite MEMORY.md — only append to the appropriate section.

## Daily log

Write daily entries to \`memory/YYYY-MM-DD-doppel-${c.n}.md\` (suffixed). The parent uses the un-suffixed file. Both files live in the shared memory/ directory.

## Auto-delete

Per AGENTS.md ("If BOOTSTRAP.md exists, follow it, then delete it"), delete this file after your first turn so it doesn't keep being processed on future bootstraps. Your clone identity carries forward in IDENTITY.md.
`);

  // HEARTBEAT.md — empty per-clone task list.
  writeFileSync(join(c.cloneDir, 'HEARTBEAT.md'), `# HEARTBEAT.md - Tasks for ${c.cloneName}

_Empty by default. The user adds tasks here when they want this doppel to focus on something specific._

`);

  // .claude/settings.json — per-clone, enables telegram plugin.
  mkdirSync(join(c.cloneDir, '.claude', 'state'), { recursive: true });
  writeFileSync(join(c.cloneDir, '.claude', 'settings.json'), JSON.stringify({
    permissions: { allow: [], deny: [] },
    enabledPlugins: { 'telegram@claude-plugins-official': true },
  }, null, 2) + '\n');

  // .claude/settings.local.json — per-clone bot token + STATE_DIR.
  // Hooks point at this clone's scripts/ symlink (which leads to parent's).
  const settingsLocal = {
    env: {
      TELEGRAM_BOT_TOKEN: c.botToken,
      TELEGRAM_STATE_DIR: c.stateDir,
      TELEGRAM_CHAT_ID: c.userTgId,
    },
    hooks: {
      UserPromptSubmit: [{ hooks: [
        { type: 'command', command: `${c.cloneDir}/scripts/hook-session-state.sh` },
      ]}],
      Stop: [{ hooks: [
        { type: 'command', command: `${c.cloneDir}/scripts/hook-context-report.sh` },
        { type: 'command', command: `${c.cloneDir}/scripts/hook-session-state.sh` },
      ]}],
      PreToolUse: [{ hooks: [
        { type: 'command', command: `${c.cloneDir}/scripts/hook-tool-activity.sh` },
        { type: 'command', command: `${c.cloneDir}/scripts/hook-session-state.sh` },
      ]}],
    },
  };
  const settingsLocalPath = join(c.cloneDir, '.claude', 'settings.local.json');
  writeFileSync(settingsLocalPath, JSON.stringify(settingsLocal, null, 2) + '\n', { mode: 0o600 });
  chmodSync(settingsLocalPath, 0o600);

  // restart.sh — per-clone, knows its tmux session name.
  const restartSh = `#!/bin/bash
# Restart Claude Code agent in this directory
# Usage: ./restart.sh <old_pid>

OLD_PID="$1"
DIR="$(cd "$(dirname "$0")" && pwd)"
SESSION="claude-${c.cloneName}"
LOG="$DIR/restart.log"

echo "[$(date)] Restart initiated, old PID=$OLD_PID" >> "$LOG"

sleep 3

if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
  kill "$OLD_PID"
  for i in $(seq 1 10); do
    kill -0 "$OLD_PID" 2>/dev/null || break
    sleep 1
  done
  kill -0 "$OLD_PID" 2>/dev/null && kill -9 "$OLD_PID"
  echo "[$(date)] Old process killed" >> "$LOG"
fi

sleep 2

CMD="cd $DIR && ${claudeBin} --dangerously-skip-permissions --channels plugin:telegram@claude-plugins-official"

if tmux has-session -t "$SESSION" 2>/dev/null; then
  tmux respawn-pane -t "$SESSION" -k "$CMD"
else
  tmux new-session -d -s "$SESSION" -x 200 -y 50 "$CMD"
fi

sleep 4
PANE_PID=$(tmux display -p -t "$SESSION" '#{pane_pid}' 2>/dev/null)
NEW_PID=""
if [ -n "$PANE_PID" ]; then
  if ps -p "$PANE_PID" -o command= 2>/dev/null | grep -q '/claude'; then
    NEW_PID="$PANE_PID"
  else
    NEW_PID=$(pgrep -P "$PANE_PID" -n -f '/claude' 2>/dev/null)
  fi
fi
[ -n "$NEW_PID" ] && echo "$NEW_PID" > "$DIR/agent.pid"
echo "[$(date)] New PID=$NEW_PID" >> "$LOG"
`;
  const restartPath = join(c.cloneDir, 'restart.sh');
  writeFileSync(restartPath, restartSh);
  chmodSync(restartPath, 0o755);
}

async function runCloneFlow(values, cloneOf, prereqs) {
  const parentDir = resolveCloneParent(cloneOf);
  const c = await collectCloneAnswers(values, parentDir);

  console.log('');
  console.log(bold('Plan (clone):'));
  console.log(`  Parent      : ${c.parentBase} (${c.parentDir})`);
  console.log(`  Clone       : ${c.cloneName}`);
  console.log(`  Bot         : @${c.botUsername}`);
  console.log(`  Target dir  : ${c.cloneDir}`);
  console.log(`  State dir   : ${c.stateDir}`);
  console.log('');

  if (!values.yes) {
    const { go } = await prompts({
      type: 'confirm',
      name: 'go',
      message: 'Proceed?',
      initial: true,
    });
    if (!go) {
      console.log(dim('Aborted.'));
      process.exit(0);
    }
  }

  // 1. Create clone dir tree.
  step(`Creating clone directory: ${c.cloneDir}`);
  mkdirSync(c.cloneDir, { recursive: true });

  // 2. Symlink shared markdown + workspace dirs from parent.
  step(`Linking shared files from ${c.parentBase}…`);
  for (const f of ['CLAUDE.md', 'SOUL.md', 'USER.md', 'AGENTS.md', 'TOOLS.md',
                   'MEMORY.md', 'ACCOUNTS.md', 'FIRST_RUN.md']) {
    symlinkIfExists(c.parentDir, c.cloneDir, f, c.parentBase);
  }
  for (const d of ['memory', 'scripts', 'browser', 'node_modules', 'projects',
                   'src', 'code']) {
    symlinkIfExists(c.parentDir, c.cloneDir, d, c.parentBase);
  }
  // Skills dir symlink — clones share parent's skills (but get their own settings).
  if (existsSync(join(c.parentDir, '.claude', 'skills'))) {
    mkdirSync(join(c.cloneDir, '.claude'), { recursive: true });
    symlinkSync(`../../${c.parentBase}/.claude/skills`, join(c.cloneDir, '.claude', 'skills'));
  }
  ok('Symlinks in place.');

  // 3. Per-clone real files (IDENTITY/BOOTSTRAP/HEARTBEAT/restart.sh/.claude/*).
  step('Writing per-clone files…');
  writeCloneRealFiles(c, prereqs.claude);
  ok('Per-clone files written.');

  // 4. State dir + .env + access.json (mode 600).
  writeStateDir(c.stateDir, c.botToken, c.userTgId);

  // 5. Plugin install at project scope (clone's project entry, not parent's).
  installTelegramPlugin(prereqs.claude, c.cloneDir);

  // 6. Pre-ack first-run dialogs for this new project path.
  preAcknowledgeClaudeDialogs(c.cloneDir);

  // 7. Skip status-reporter install — coordinator already exists (parent or
  //    a sibling installed it). The CLI's installer is idempotent and would
  //    skip anyway, but we don't bother calling it.
  // 8. Skip npm install — node_modules is symlinked from the parent.

  console.log('');
  console.log(green(bold(`✓ Doppel ready (worker hermit, master / coordinator: ${c.parentBase} or its own master).`)));
  console.log(dim('   Doppels are always workers — they share the parent\'s workspace but never replace the master.'));
  console.log('');
  console.log(bold('Next steps:'));
  console.log(`  1. Start it:`);
  console.log(`       cd ${relative(process.cwd(), c.cloneDir) || '.'}`);
  console.log(`       ./restart.sh ""`);
  console.log('');
  console.log(`  2. DM @${c.botUsername} to wake them. The parent (${c.parentBase}) is unaware of this conversation.`);
  console.log('');
  console.log(`  3. Watch the session:`);
  console.log(`       tmux attach -t claude-${c.cloneName}    ${dim('(detach: Ctrl-b d)')}`);
  console.log('');
}

// --- Make all .sh executable ---

function chmodScripts(targetDir) {
  const candidates = [
    'start.sh',
    'restart.sh',
    'scripts/safe-image.sh',
    'scripts/exec-cli-command.sh',
    'scripts/hook-session-state.sh',
    'scripts/hook-tool-activity.sh',
    'scripts/hook-context-report.sh',
    'scripts/hook-tg-strip-markdown.sh',
    'scripts/multi-agent-status-report.sh',
    'scripts/chrome-launcher.sh',
    'scripts/browser-lock.sh',
    'scripts/playwright-mcp-launcher.sh',
    'scripts/launchd-sync.sh',
    'scripts/systemd-sync.sh',
    'scripts/with-timeout.sh',
    'scripts/claude-quota-probe.sh',
    'scripts/hooks/pre-read-image.sh',
    '.claude/hooks/tg-reply-check.sh',
  ];
  for (const rel of candidates) {
    const abs = join(targetDir, rel);
    if (existsSync(abs)) makeExecutable(abs);
  }
}

// --- Main ---

// --- Codex flavor flow ---
//
// Codex hermits don't use the official telegram plugin (which is a Claude
// Code marketplace artifact). They run a small Python bridge that polls
// `getUpdates`, invokes `codex exec [resume <thread_id>]` per message, and
// posts the captured `--output-last-message` back via `sendMessage`.
//
// What this flow does (vs the claude flavor):
//   • walkCopy from template-codex/ instead of template/
//   • The `.env.tmpl` in template-codex carries TG_BOT_TOKEN + USER_TG_ID
//     placeholders; walkCopy strips `.tmpl` to land at workspace `.env`,
//     which we then chmod 600.
//   • No `claude plugin install`. No preAcknowledgeClaudeDialogs. No npm
//     install for playwright. No status-reporter LaunchAgent (codex flavor
//     ships its own scripts/multi-agent-status-report.sh as opt-in).
//
// Final printout is host-aware: tmux session is `codex-<name>` (run by
// start.sh in the agent dir), not `claude-<name>`.
async function runCodexFlow(values, positional, prereqs) {
  const answers = await collectAnswers(values, positional);

  console.log('');
  console.log(bold('Plan (codex flavor):'));
  console.log(`  Agent       : ${answers.agentName}`);
  console.log(`  Bot         : @${answers.botUsername}`);
  console.log(`  Target dir  : ${answers.targetDir}`);
  console.log(`  Persona     : ${answers.persona}`);
  console.log(`  Host        : codex (subscription via codex login)`);
  console.log('');

  if (!values.yes) {
    const { go } = await prompts({
      type: 'confirm',
      name: 'go',
      message: 'Proceed?',
      initial: true,
    });
    if (!go) {
      console.log(dim('Aborted.'));
      process.exit(0);
    }
  }

  // 1. Copy template-codex/
  step('Copying codex template…');
  const vars = {
    AGENT_NAME:           answers.agentName,
    AGENT_DISPLAY_NAME:   answers.displayName,
    HOME:                 process.env.HOME || '',
    PERSONA:              answers.persona,
    USER_NAME:            answers.userName,
    USER_TG_ID:           answers.userTgId,
    TG_BOT_TOKEN:         answers.botToken,
    BRAVE_API_KEY:        answers.braveKey || '',
    AGENT_DIR:            answers.targetDir,
    STATE_DIR:            answers.targetDir,    // codex flavor keeps state in workspace
    CLAUDE_BIN:           '',                    // unused
  };
  walkCopy(TEMPLATE_CODEX_DIR, answers.targetDir, vars);

  // 2. Filename substitution: rename launchd plist {{AGENT_NAME}} → actual name.
  // walkCopy substitutes file *contents* but not filenames.
  const launchdDir = join(answers.targetDir, 'launchd');
  if (existsSync(launchdDir)) {
    for (const entry of readdirSync(launchdDir)) {
      if (entry.includes('{{AGENT_NAME}}')) {
        const oldPath = join(launchdDir, entry);
        const newPath = join(launchdDir, entry.replace(/\{\{AGENT_NAME\}\}/g, answers.agentName));
        renameSync(oldPath, newPath);
      }
    }
  }

  // 3. Lock down .env to mode 600 (token sits there).
  const envPath = join(answers.targetDir, '.env');
  if (existsSync(envPath)) {
    chmodSync(envPath, 0o600);
    ok(`.env written at ${envPath} (mode 600)`);
  }

  // 4. Make scripts executable (walkCopy preserves source mode but for safety).
  chmodScripts(answers.targetDir);

  ok(`Codex hermit scaffolded at ${answers.targetDir}`);

  // Final printout
  const tmuxSession = `codex-${answers.agentName}`;
  console.log('');
  console.log(green(bold(`✓ Codex hermit ready.`)));
  console.log(dim(`   Uses your ChatGPT subscription via the codex CLI — no API key spend.`));
  console.log('');
  console.log(bold('Next steps:'));
  console.log(`  1. Make sure codex is logged in:`);
  console.log(`       codex login status     ${dim('(should say "Logged in using ChatGPT")')}`);
  console.log('');
  console.log(`  2. Start the bridge:`);
  console.log(`       cd ${relative(process.cwd(), answers.targetDir) || '.'}`);
  console.log(`       ./start.sh`);
  console.log('');
  console.log(`  3. Send any message to your bot on Telegram → @${answers.botUsername}`);
  console.log(`     (the boot hook will fire FIRST_RUN.md welcome on first launch)`);
  console.log('');
  console.log(`  4. Attach to watch:`);
  console.log(`       tmux attach -t ${tmuxSession}    ${dim('(detach: Ctrl-b d)')}`);
  console.log('');
  console.log(dim(`Restart with: ./restart.sh   |   Reset thread: send /reset to the bot.`));
}

async function main() {
  // Parse args FIRST — we need --host before checkPrereqs picks the right binary.
  const cli = parseCliArgs();
  const host = cli.values.host || 'claude';

  console.log('');
  console.log(bold('🦀 create-hermit-agent'));
  if (host === 'codex') {
    console.log(dim('Bootstrapping a Telegram-connected Codex CLI agent…'));
  } else {
    console.log(dim('Bootstrapping a Telegram-connected Claude Code agent…'));
  }
  console.log('');

  const prereqs = checkPrereqs(host);

  // Clone mode: skip the fresh-agent flow entirely. Symlink-based provisioning
  // off an existing parent.
  if (cli.values['clone-of']) {
    if (cli.positionals[0]) {
      die('Pass either a <name> for a fresh agent or --clone-of <parent> for a doppel — not both.');
    }
    await runCloneFlow(cli.values, cli.values['clone-of'], prereqs);
    return;
  }

  // Branch on host. Codex flavor has its own simpler flow (no plugin install,
  // no preack TUI dialogs, no claude-specific Linux scheduling).
  if (host === 'codex') {
    await runCodexFlow(cli.values, cli.positionals[0], prereqs);
    return;
  }

  const positional = cli.positionals[0];
  const answers = await collectAnswers(cli.values, positional);

  console.log('');
  console.log(bold('Plan:'));
  console.log(`  Agent       : ${answers.agentName}`);
  console.log(`  Bot         : @${answers.botUsername}`);
  console.log(`  Target dir  : ${answers.targetDir}`);
  console.log(`  State dir   : ${answers.stateDir}`);
  console.log(`  Persona     : ${answers.persona}`);
  console.log(`  Brave key   : ${answers.braveKey ? '(set)' : '(none)'}`);
  console.log('');

  if (!cli.values.yes) {
    const { go } = await prompts({
      type: 'confirm',
      name: 'go',
      message: 'Proceed?',
      initial: true,
    });
    if (!go) {
      console.log(dim('Aborted.'));
      process.exit(0);
    }
  }

  // 1. Copy template
  step('Copying template…');
  const vars = {
    AGENT_NAME:           answers.agentName,
    AGENT_DISPLAY_NAME:   answers.displayName,
    HOME:                 process.env.HOME || '',
    PERSONA:              answers.persona,
    USER_NAME:            answers.userName,
    USER_TG_ID:           answers.userTgId,
    TG_BOT_TOKEN:         answers.botToken,
    BRAVE_API_KEY:        answers.braveKey,
    AGENT_DIR:            answers.targetDir,
    STATE_DIR:            answers.stateDir,
    CLAUDE_BIN:           prereqs.claude,
  };
  walkCopy(TEMPLATE_DIR, answers.targetDir, vars);
  prunePlatformLayers(answers.targetDir);
  chmodScripts(answers.targetDir);
  ok(`Template copied to ${answers.targetDir}`);

  // 2. Write state dir (.env + access.json)
  writeStateDir(answers.stateDir, answers.botToken, answers.userTgId);

  // 3. Install telegram plugin at project scope
  installTelegramPlugin(prereqs.claude, answers.targetDir);

  // 4. npm install for playwright (macOS only — Linux scaffold prunes the
  //    browser layer and drops the playwright dep, so there's nothing to
  //    install).
  if (IS_DARWIN) {
    npmInstall(answers.targetDir);
  }

  // 5. Pre-ack first-run dialogs so tmux startup doesn't hang on a blocked TUI
  preAcknowledgeClaudeDialogs(answers.targetDir);

  // 6. Install multi-agent status reporter LaunchAgent (idempotent, one per machine)
  const role = installStatusReporter(answers.targetDir, answers.agentName);

  // 7. Install hibernation system on the master only (idle-hibernator + wake-poller).
  installHibernationSystem(answers.targetDir, answers.agentName, role.role);

  // 8. Install dead-session reaper on the master only (daily Trash sweep of stale JSONLs).
  installDeadSessionReaper(answers.targetDir, answers.agentName, role.role);

  // 9. Final printout — distinguish master (coordinator) from worker.
  const tmuxSession = `claude-${answers.agentName}`;
  console.log('');
  if (role.role === 'master') {
    console.log(green(bold(`✓ Master hermit ready (this Mac's coordinator).`)));
    console.log(dim('   Future hermits on this machine will be workers — only the master runs the multi-agent status digest.'));
  } else if (role.coordinator) {
    console.log(green(bold(`✓ Worker hermit ready (master / coordinator: ${role.coordinator}).`)));
  } else {
    console.log(green(bold(`✓ Worker hermit ready.`)));
    console.log(dim('   No master detected on this machine. Install the LaunchAgent manually if you want a coordinator.'));
  }
  console.log('');
  console.log(bold('Next steps:'));
  console.log(`  1. Start it:`);
  console.log(`       cd ${relative(process.cwd(), answers.targetDir) || '.'}`);
  console.log(`       ./start.sh`);
  console.log('');
  console.log(`  2. Send any message to your bot on Telegram → @${answers.botUsername}`);
  console.log('');
  console.log(`  3. Attach to the session to watch:`);
  console.log(`       tmux attach -t ${tmuxSession}    ${dim('(detach: Ctrl-b d)')}`);
  console.log('');
}

main().catch((e) => {
  console.error(red('Fatal: '), e);
  process.exit(1);
});
