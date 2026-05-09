#!/usr/bin/env python3
"""
Telegram <-> Codex bridge daemon.

Polls Telegram via getUpdates long-poll, runs `codex exec` (or resume) per
incoming message, captures the agent's last message, and replies via
sendMessage.

Run from the agent workspace root, so codex picks up AGENTS.md and its
siblings as the working-directory persona.

Env required:
  TELEGRAM_BOT_TOKEN  -- bot token from @BotFather
  TELEGRAM_CHAT_ID    -- only this chat_id is allowed (allowlist)

State files:
  state/thread.txt    -- current codex thread_id (deleted = next msg starts a new thread)
  state/update_id.txt -- last Telegram update_id processed
"""

import json
import os
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
from pathlib import Path

WORKSPACE = Path(__file__).resolve().parent.parent
STATE_DIR = WORKSPACE / "state"
HOOKS_DIR = WORKSPACE / "scripts" / "hooks"
THREAD_FILE = STATE_DIR / "thread.txt"
UPDATE_ID_FILE = STATE_DIR / "update_id.txt"
LAST_MSG_FILE = STATE_DIR / "last.txt"

# Codex's built-in image_gen tool writes png artifacts here (per thread).
# We snapshot the tree before each codex turn and diff after, so any new
# files generated during the turn get pushed back to Telegram via sendPhoto.
GENERATED_DIR = Path.home() / ".codex" / "generated_images"
IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".webp", ".gif"}

POLL_TIMEOUT = 25
HTTP_TIMEOUT = 30

BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN")
ALLOWED_CHAT = os.environ.get("TELEGRAM_CHAT_ID")

if not BOT_TOKEN or not ALLOWED_CHAT:
    print("missing TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID env", file=sys.stderr)
    sys.exit(2)

API = f"https://api.telegram.org/bot{BOT_TOKEN}"


def tg(method, **params):
    url = f"{API}/{method}?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(url, timeout=HTTP_TIMEOUT) as r:
        return json.load(r)


def send(chat_id, text):
    body = urllib.parse.urlencode({"chat_id": chat_id, "text": text}).encode()
    req = urllib.request.Request(f"{API}/sendMessage", data=body, method="POST")
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as r:
        return json.load(r)


def send_photo(chat_id, photo_path, caption=None):
    """POST a file to Telegram sendPhoto. Builds multipart/form-data manually
    so we keep stdlib-only and don't put the token / file content on argv.
    """
    boundary = f"----TgBridge{int(time.time() * 1000)}"
    with open(photo_path, "rb") as f:
        data = f.read()
    filename = os.path.basename(photo_path)
    parts = [f"--{boundary}\r\n"
             f'Content-Disposition: form-data; name="chat_id"\r\n\r\n'
             f"{chat_id}\r\n".encode()]
    if caption:
        parts.append((f"--{boundary}\r\n"
                      f'Content-Disposition: form-data; name="caption"\r\n\r\n'
                      f"{caption}\r\n").encode())
    parts.append((f"--{boundary}\r\n"
                  f'Content-Disposition: form-data; name="photo"; filename="{filename}"\r\n'
                  f"Content-Type: application/octet-stream\r\n\r\n").encode())
    parts.append(data)
    parts.append(f"\r\n--{boundary}--\r\n".encode())
    body = b"".join(parts)
    req = urllib.request.Request(
        f"{API}/sendPhoto",
        data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as r:
        return json.load(r)


def snapshot_generated():
    """Return a set of absolute paths for image artifacts under GENERATED_DIR."""
    if not GENERATED_DIR.exists():
        return set()
    out = set()
    for p in GENERATED_DIR.rglob("*"):
        if p.is_file() and p.suffix.lower() in IMAGE_EXTS:
            out.add(str(p))
    return out


def chat_action(chat_id, action="typing"):
    """Show a transient '... is typing' indicator in the chat. Lasts ~5s."""
    try:
        body = urllib.parse.urlencode({"chat_id": chat_id, "action": action}).encode()
        req = urllib.request.Request(f"{API}/sendChatAction", data=body, method="POST")
        urllib.request.urlopen(req, timeout=HTTP_TIMEOUT).read()
    except Exception:
        pass


class TypingPulse:
    """Resends sendChatAction('typing') every ~4s while a slow op runs.
    Usage:
        with TypingPulse(chat_id):
            slow_op()
    """

    def __init__(self, chat_id, interval=4.0):
        self.chat_id = chat_id
        self.interval = interval
        self._stop = threading.Event()
        self._t = None

    def __enter__(self):
        chat_action(self.chat_id)
        self._t = threading.Thread(target=self._loop, daemon=True)
        self._t.start()
        return self

    def __exit__(self, *exc):
        self._stop.set()
        if self._t:
            self._t.join(timeout=1.0)

    def _loop(self):
        while not self._stop.wait(self.interval):
            chat_action(self.chat_id)


def read_state(p):
    try:
        return p.read_text().strip() or None
    except FileNotFoundError:
        return None


def write_state(p, val):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(str(val))


def run_hook(name, env_extra=None, capture_stdout=False, timeout=30):
    """Run scripts/hooks/<name>.sh if it exists.
    - Returns (exit_code, stdout_str). Missing hook returns (0, "").
    - Hooks are passed env via env_extra dict on top of os.environ.
    - If capture_stdout=True, the hook's stdout (stripped) is returned and may
      be used by the caller to replace prompt/reply text (post-run pattern).
    - exit_code != 0 from a pre-run hook signals "abort this turn".
    """
    hook = HOOKS_DIR / f"{name}.sh"
    if not hook.exists():
        return 0, ""
    if not os.access(str(hook), os.X_OK):
        print(f"hook {hook} not executable, skipping", file=sys.stderr)
        return 0, ""
    env = dict(os.environ)
    if env_extra:
        env.update({k: str(v) for k, v in env_extra.items() if v is not None})
    try:
        proc = subprocess.run(
            [str(hook)],
            cwd=str(WORKSPACE),
            env=env,
            capture_output=capture_stdout,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        print(f"hook {name} timed out after {timeout}s", file=sys.stderr)
        return 124, ""
    out = (proc.stdout.strip() if capture_stdout and proc.stdout else "")
    return proc.returncode, out


CODEX_TIMEOUT_SEC = 1800  # 30 min ceiling per turn

def run_codex(prompt, thread_id=None):
    """Run codex exec (or resume) with the prompt. Returns (new_thread_id, last_message).

    Uses Popen + start_new_session so we own the process group; on timeout we
    SIGKILL the whole pgroup (codex itself spawns helper processes that subprocess.run
    + plain proc.kill() won't reach, which previously left orphans pinned to PPID=1
    and the daemon stuck in proc.wait()).
    """
    LAST_MSG_FILE.parent.mkdir(parents=True, exist_ok=True)
    if LAST_MSG_FILE.exists():
        LAST_MSG_FILE.unlink()
    cmd = ["codex", "exec"]
    if thread_id:
        cmd += ["resume", thread_id]
    cmd += [
        "--json",
        "--output-last-message", str(LAST_MSG_FILE),
        "--skip-git-repo-check",
        # Codex defaults to --sandbox read-only, which blocks writes and
        # network. We want hermit agents to behave like claude flavor's
        # --dangerously-skip-permissions: full filesystem + network, no
        # approval prompts. --dangerously-bypass-approvals-and-sandbox
        # (alias --yolo) sets sandbox=danger-full-access + ask=never.
        "--dangerously-bypass-approvals-and-sandbox",
        prompt,
    ]
    proc = subprocess.Popen(
        cmd,
        cwd=str(WORKSPACE),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    try:
        stdout, _stderr = proc.communicate(timeout=CODEX_TIMEOUT_SEC)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(proc.pid), 9)  # SIGKILL whole process group
        except (ProcessLookupError, PermissionError):
            pass
        try:
            proc.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            pass  # whole group still won't die; let GC handle eventually
        raise  # re-raise so handle() messages the user
    new_thread = thread_id
    for line in stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        if ev.get("type") == "thread.started":
            new_thread = ev.get("thread_id") or new_thread
    last = LAST_MSG_FILE.read_text() if LAST_MSG_FILE.exists() else ""
    if not last:
        last = f"(codex returned no message; exit={proc.returncode})\n--stderr tail--\n{proc.stderr[-500:]}"
    return new_thread, last.strip()


ADMIN_HELP = (
    "Admin commands handled by the bridge daemon (not by codex):\n"
    "/help      — this list\n"
    "/status    — daemon pid, current thread, daily-log size\n"
    "/reset     — start a new codex thread (clears state/thread.txt)\n"
    "/restart   — full bridge restart via restart.sh\n"
    "Anything else is forwarded to codex as a normal turn."
)


def handle_admin(chat_id, text):
    """Return True if `text` is a recognized admin command and was handled."""
    cmd = text.strip().split()[0].lower()
    if cmd == "/help":
        send(chat_id, ADMIN_HELP)
        return True
    if cmd == "/status":
        thread = read_state(THREAD_FILE) or "(none)"
        update_id = read_state(UPDATE_ID_FILE) or "0"
        daily_log = WORKSPACE / "memory" / f"{time.strftime('%Y-%m-%d')}.md"
        try:
            log_size = daily_log.stat().st_size if daily_log.exists() else 0
        except OSError:
            log_size = 0
        send(chat_id, (
            f"daemon pid {os.getpid()}\n"
            f"thread {thread[:8] + ('…' if len(thread) > 8 else '')}\n"
            f"last update_id {update_id}\n"
            f"daily log {log_size} bytes ({daily_log.name})"
        ))
        return True
    if cmd == "/reset":
        if THREAD_FILE.exists():
            THREAD_FILE.unlink()
        send(chat_id, "thread cleared. next message starts a fresh codex thread.")
        return True
    if cmd == "/restart":
        send(chat_id, "restarting bridge in ~1s …")
        # Spawn restart.sh detached; daemon dies, tmux session is killed and
        # respawned by the script. State is preserved on disk.
        subprocess.Popen(
            [str(WORKSPACE / "restart.sh")],
            cwd=str(WORKSPACE),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        return True
    if cmd.startswith("/") and cmd not in ("/start",):
        # Unknown slash-command — tell user, do NOT pass to codex.
        send(chat_id, f"unknown admin command: {cmd}\n\n{ADMIN_HELP}")
        return True
    return False


def handle(msg):
    chat_id = str(msg.get("chat", {}).get("id"))
    if chat_id != str(ALLOWED_CHAT):
        print(f"ignored msg from unauthorized chat_id={chat_id}", file=sys.stderr)
        return
    text = msg.get("text") or ""
    if not text:
        return
    print(f"-> {text[:120]}", flush=True)

    if handle_admin(chat_id, text):
        print("<- (admin)", flush=True)
        return

    thread = read_state(THREAD_FILE)

    # pre-run hook — abort if exit != 0
    rc, _ = run_hook("pre-run", env_extra={
        "CODEX_PROMPT": text,
        "CODEX_THREAD_ID": thread or "",
        "CODEX_CHAT_ID": chat_id,
    })
    if rc != 0:
        print(f"pre-run hook aborted turn (exit={rc})", file=sys.stderr)
        send(chat_id, f"(pre-run hook aborted, exit={rc})")
        return

    images_before = snapshot_generated()
    try:
        with TypingPulse(chat_id):
            new_thread, reply = run_codex(text, thread_id=thread)
    except subprocess.TimeoutExpired:
        send(chat_id, f"(codex timed out after {CODEX_TIMEOUT_SEC // 60} min — process group killed; thread preserved, send another message to continue)")
        return
    except Exception as e:
        send(chat_id, f"(bridge error: {type(e).__name__}: {e})")
        return

    if new_thread and new_thread != thread:
        write_state(THREAD_FILE, new_thread)
    if not reply:
        reply = "(empty reply)"

    # New images generated during this turn — sendPhoto each before the text
    # reply, so user sees the artifact then the explanation.
    images_after = snapshot_generated()
    new_images = sorted(images_after - images_before)
    for img in new_images:
        try:
            chat_action(chat_id, "upload_photo")
            send_photo(chat_id, img)
            print(f"<- photo {os.path.basename(img)} ({os.path.getsize(img)} bytes)", flush=True)
        except Exception as e:
            print(f"sendPhoto error for {img}: {type(e).__name__}: {e}", file=sys.stderr)
            # Fall through — user still gets the text reply

    # post-run hook — its stdout, if non-empty, replaces the reply
    rc, transformed = run_hook("post-run", env_extra={
        "CODEX_PROMPT": text,
        "CODEX_REPLY": reply,
        "CODEX_THREAD_ID": new_thread or "",
        "CODEX_CHAT_ID": chat_id,
    }, capture_stdout=True)
    if rc == 0 and transformed:
        reply = transformed

    # Telegram message limit is 4096 chars; chunk if longer.
    total_sent = 0
    while reply:
        chunk, reply = reply[:4000], reply[4000:]
        send(chat_id, chunk)
        total_sent += len(chunk)
    print(f"<- ({total_sent} chars sent)", flush=True)


def main():
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    last_update = int(read_state(UPDATE_ID_FILE) or 0)
    print(f"codex-hermit bridge starting; resuming from update_id={last_update}", flush=True)

    # boot hook — fire-and-forget at daemon startup (Codex equivalent of SessionStart)
    rc, _ = run_hook("boot")
    if rc != 0:
        print(f"boot hook exited with {rc} (continuing anyway)", file=sys.stderr)
    while True:
        try:
            resp = tg(
                "getUpdates",
                offset=last_update + 1,
                timeout=POLL_TIMEOUT,
                allowed_updates='["message"]',
            )
        except Exception as e:
            print(f"getUpdates error: {e}", file=sys.stderr)
            time.sleep(5)
            continue
        if not resp.get("ok"):
            print(f"getUpdates not ok: {resp}", file=sys.stderr)
            time.sleep(5)
            continue
        for upd in resp.get("result", []):
            last_update = upd["update_id"]
            write_state(UPDATE_ID_FILE, last_update)
            msg = upd.get("message")
            if msg:
                handle(msg)


if __name__ == "__main__":
    main()
