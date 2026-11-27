#!/usr/bin/env python3
"""Read a Slack browser session from the Slack desktop app over CDP.

Slack refuses --remote-debugging-port on its default profile, so this copies the
profile to a temporary folder, starts Slack against the copy with CDP on
127.0.0.1, reads the xoxc tokens from localStorage and the HttpOnly d cookie
from the browser context, verifies each pair with auth.test, writes the chosen
pair to the given files (mode 600), then removes the copy and restarts Slack.

No token or cookie is ever printed. Stdlib only; Python 3.8+.
"""
import argparse
import base64
import json
import os
import re
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

APP_CANDIDATES = (
    "/Applications/Slack.app",
    os.path.expanduser("~/Applications/Slack.app"),
)
PROFILE = os.path.expanduser("~/Library/Application Support/Slack")
IGNORE = shutil.ignore_patterns(
    "Cache", "Code Cache", "GPUCache", "GraphiteDawnCache", "DawnGraphiteCache",
    "DawnWebGPUCache", "Service Worker", "logs", "Crashpad", "blob_storage",
    "Singleton*", "lockfile",
)


class AuthError(Exception):
    pass


def note(message):
    print(f"slack-relay auth: {message}", file=sys.stderr)


def find_slack():
    override = os.environ.get("SLACK_APP_PATH")
    if override:
        binary = os.path.join(override, "Contents", "MacOS", "Slack") if override.endswith(".app") else override
        if os.access(binary, os.X_OK):
            return os.path.abspath(override if override.endswith(".app") else os.path.dirname(os.path.dirname(binary))), binary
        raise AuthError(f"SLACK_APP_PATH does not point at a Slack app: {override}")
    for app in APP_CANDIDATES:
        binary = os.path.join(app, "Contents", "MacOS", "Slack")
        if os.access(binary, os.X_OK):
            return app, binary
    try:
        found = subprocess.run(
            ["mdfind", "kMDItemCFBundleIdentifier == 'com.tinyspeck.slackmacgap'"],
            capture_output=True, text=True, timeout=10,
        ).stdout.splitlines()
    except Exception:
        found = []
    for app in found:
        binary = os.path.join(app, "Contents", "MacOS", "Slack")
        if os.access(binary, os.X_OK):
            return app, binary
    raise AuthError("Slack.app not found; install Slack or pass --token-file/--cookie-file manually")


def pids(pattern=None, exact=False):
    cmd = ["pgrep", "-f" if pattern else "-x", pattern or "Slack"]
    out = subprocess.run(cmd, capture_output=True, text=True)
    return [int(line) for line in out.stdout.split() if line.isdigit()]


def wait_gone(pattern=None, exact=False, timeout=15.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not pids(pattern, exact):
            return True
        time.sleep(0.25)
    return not pids(pattern, exact)


def quit_pids(pid_list, timeout=10.0):
    for pid in pid_list:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not any(_alive(pid) for pid in pid_list):
            return
        time.sleep(0.25)
    for pid in pid_list:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def _alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def stop_slack(app_path):
    """Quit the user's Slack, returning True if it was running."""
    running = pids()
    if not running:
        return False
    note("restarting Slack to read its local session (it reopens in a few seconds)")
    subprocess.run(
        ["osascript", "-e", 'quit app "Slack"'],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10,
    )
    if not wait_gone(timeout=15):
        quit_pids(pids())
    return True


def free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def http_json(url, timeout=3.0):
    with urllib.request.urlopen(url, timeout=timeout) as response:
        return json.loads(response.read().decode())


def wait_cdp(port, deadline=30.0):
    end = time.time() + deadline
    while time.time() < end:
        try:
            return http_json(f"http://127.0.0.1:{port}/json/version", timeout=1.0)
        except Exception:
            time.sleep(0.4)
    raise AuthError("Slack did not open a CDP port; check ~/Library/Application Support/Slack")


def wait_page(port, deadline=30.0):
    end = time.time() + deadline
    while time.time() < end:
        try:
            targets = http_json(f"http://127.0.0.1:{port}/json", timeout=1.0)
        except Exception:
            targets = []
        pages = [t for t in targets if t.get("type") == "page" and t.get("url", "").startswith("https://app.slack.com/")]
        if pages:
            return pages[0]
        time.sleep(0.4)
    raise AuthError("Slack opened but no app.slack.com page appeared; sign in to Slack and rerun")


class WS:
    """Minimal CDP WebSocket client (text frames, ping/pong, fragmentation)."""

    def __init__(self, url):
        parsed = urllib.parse.urlparse(url)
        if parsed.scheme != "ws" or not parsed.hostname:
            raise AuthError(f"bad CDP websocket URL: {url}")
        self.sock = socket.create_connection((parsed.hostname, parsed.port or 80), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode()
        path = parsed.path + (("?" + parsed.query) if parsed.query else "")
        request = (
            f"GET {path} HTTP/1.1\r\nHost: {parsed.hostname}:{parsed.port}\r\n"
            "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
        )
        self.sock.sendall(request.encode())
        response = b""
        while b"\r\n\r\n" not in response:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise AuthError("Slack closed the CDP socket during the handshake")
            response += chunk
        status = response.split(b"\r\n", 1)[0]
        if b" 101 " not in status:
            raise AuthError(f"CDP handshake failed: {status.decode(errors='replace')}")
        self.buffer = response.split(b"\r\n\r\n", 1)[1]
        self.next_id = 0

    def _read(self, count):
        while len(self.buffer) < count:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise AuthError("Slack closed the CDP socket")
            self.buffer += chunk
        data, self.buffer = self.buffer[:count], self.buffer[count:]
        return data

    def _send(self, payload, opcode=1):
        header = bytearray([0x80 | opcode])
        mask = os.urandom(4)
        length = len(payload)
        if length < 126:
            header.append(0x80 | length)
        elif length < 65536:
            header.append(0x80 | 126)
            header += struct.pack(">H", length)
        else:
            header.append(0x80 | 127)
            header += struct.pack(">Q", length)
        header += mask
        self.sock.sendall(bytes(header) + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def _recv(self):
        first, second = self._read(2)
        fin = bool(first & 0x80)
        opcode = first & 0x0F
        length = second & 0x7F
        if length == 126:
            length = struct.unpack(">H", self._read(2))[0]
        elif length == 127:
            length = struct.unpack(">Q", self._read(8))[0]
        mask = self._read(4) if second & 0x80 else None
        payload = self._read(length)
        if mask:
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        return fin, opcode, payload

    def call(self, method, params=None):
        self.next_id += 1
        self._send(json.dumps({"id": self.next_id, "method": method, "params": params or {}}).encode())
        chunks = []
        while True:
            fin, opcode, payload = self._recv()
            if opcode == 9:
                self._send(payload, 10)
                continue
            if opcode == 8:
                raise AuthError("Slack closed the CDP connection")
            chunks.append(payload)
            if not fin:
                continue
            message = json.loads(b"".join(chunks).decode())
            chunks = []
            if message.get("id") != self.next_id:
                continue
            if "error" in message:
                raise AuthError(f"CDP {method}: {message['error'].get('message', message['error'])}")
            return message.get("result", {})

    def close(self):
        try:
            self._send(b"", 8)
        except Exception:
            pass
        try:
            self.sock.close()
        except Exception:
            pass


TEAMS_JS = """
(() => {
  try {
    const cfg = JSON.parse(localStorage.getItem('localConfig_v2') || '{}');
    const teams = cfg.teams || {};
    return JSON.stringify(Object.values(teams).map(t => ({
      name: t.name, domain: t.domain, token: t.token, url: t.url
    })));
  } catch (e) {
    return JSON.stringify({ error: String(e) });
  }
})()
"""

READY_JS = """
(() => {
  try {
    return JSON.stringify({ href: location.href, ready: document.readyState, keys: localStorage.length });
  } catch (e) {
    return JSON.stringify({ error: String(e) });
  }
})()
"""

TOKENS_JS = """
(() => {
  const found = new Set();
  for (let i = 0; i < localStorage.length; i++) {
    const value = localStorage.getItem(localStorage.key(i)) || '';
    for (const match of value.matchAll(/xoxc-[A-Za-z0-9-]{20,}/g)) found.add(match[0]);
  }
  return JSON.stringify([...found].map(token => ({ token })));
})()
"""


def wait_ready(ws, deadline=30.0):
    """The target URL appears before the document commits; localStorage is denied until then."""
    end = time.time() + deadline
    last = ""
    while time.time() < end:
        result = ws.call("Runtime.evaluate", {"expression": READY_JS, "returnByValue": True})
        value = result.get("result", {}).get("value") or "{}"
        try:
            state = json.loads(value)
        except Exception:
            state = {}
        if not state.get("error") and state.get("ready") in ("interactive", "complete"):
            return state
        last = state.get("error") or state.get("ready") or ""
        time.sleep(0.4)
    raise AuthError(f"Slack's page did not become readable ({last or 'no answer'}); sign in to Slack and rerun")


def read_teams(ws):
    result = ws.call("Runtime.evaluate", {"expression": TEAMS_JS, "returnByValue": True})
    value = result.get("result", {}).get("value")
    if value is None:
        raise AuthError("Slack did not return its workspace list")
    teams = json.loads(value)
    if isinstance(teams, dict) and teams.get("error"):
        raise AuthError(f"could not read Slack's local config: {teams['error']}")
    teams = [t for t in teams if t.get("token")]
    if teams:
        return teams
    result = ws.call("Runtime.evaluate", {"expression": TOKENS_JS, "returnByValue": True})
    value = result.get("result", {}).get("value") or "[]"
    teams = json.loads(value)
    if not teams:
        raise AuthError("Slack has no signed-in workspaces; sign in to Slack and rerun")
    return teams


def read_d_cookies(ws):
    try:
        cookies = ws.call("Network.getAllCookies").get("cookies", [])
    except AuthError:
        cookies = ws.call("Storage.getCookies").get("cookies", [])
    values = []
    for cookie in cookies:
        if cookie.get("name") != "d":
            continue
        if "slack.com" not in cookie.get("domain", ""):
            continue
        value = cookie.get("value", "")
        if value.startswith("xoxd-") and value not in values:
            values.append(value)
    if not values:
        raise AuthError("Slack's d cookie was not in the browser context; sign in to Slack and rerun")
    return values


def api(method, params, token, cookie):
    body = urllib.parse.urlencode(params).encode()
    request = urllib.request.Request(
        f"https://slack.com/api/{method}",
        data=body,
        headers={
            "Authorization": f"Bearer {token}",
            "Cookie": f"d={cookie}",
            "Content-Type": "application/x-www-form-urlencoded",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.loads(response.read().decode())
    except Exception as error:
        return {"ok": False, "error": str(error)}


def channel_id(value):
    if not value:
        return ""
    match = re.search(r"/archives/([A-Z0-9]+)", value)
    if match:
        return match.group(1)
    return value[3:] if value.startswith("id:") else value


def workspace_key(value):
    value = (value or "").strip().lower().rstrip("/")
    if value.startswith("http"):
        value = (urllib.parse.urlparse(value).hostname or "").split(".")[0]
    return value


def matches_workspace(item, wanted):
    wanted = workspace_key(wanted)
    if not wanted:
        return True
    candidates = {
        workspace_key(item.get("domain")),
        workspace_key(item.get("name")),
        workspace_key(item.get("team")),
        workspace_key(item.get("url")),
    }
    return wanted in candidates


def select(sessions, workspace, channel):
    if workspace:
        sessions = [s for s in sessions if matches_workspace(s, workspace)]
        if not sessions:
            raise AuthError(f"no signed-in workspace matches --workspace {workspace!r}")
    if channel:
        channel = channel_id(channel)
        matched = []
        for session in sessions:
            body = api("conversations.info", {"channel": channel}, session["token"], session["cookie"])
            if body.get("ok") and (body.get("channel") or {}).get("id") == channel:
                matched.append(session)
        if not matched:
            raise AuthError(f"channel {channel} is not visible to the signed-in workspaces")
        sessions = matched
    if len(sessions) == 1:
        return sessions[0]
    if not sessions:
        raise AuthError("Slack did not authenticate; sign in to Slack and rerun")
    names = ", ".join(f"{s.get('name') or s.get('team')} ({s.get('domain') or '?'})" for s in sessions)
    raise AuthError(f"several workspaces are signed in: {names}; pass --workspace <domain>")


def workspace_row(item):
    return {key: item[key] for key in ("name", "domain", "team", "url", "user_id")}


def write_secret(path, value):
    path = os.path.expanduser(path)
    folder = os.path.dirname(path)
    if folder:
        os.makedirs(folder, exist_ok=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w") as handle:
        handle.write(value + "\n")
    os.chmod(path, 0o600)


def cleanup(proc, profile, app_path, reopen):
    if proc is not None:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            proc.wait(timeout=10)
        except Exception:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except ProcessLookupError:
                pass
    leftover = pids(f"--user-data-dir={profile}") if profile else []
    if leftover:
        quit_pids(leftover, timeout=5)
    if profile:
        shutil.rmtree(profile, ignore_errors=True)
    if reopen:
        subprocess.run(["open", "-a", app_path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main():
    parser = argparse.ArgumentParser(description="Read Slack's xoxc token and d cookie from the desktop app.")
    parser.add_argument("--token-out", required=True)
    parser.add_argument("--cookie-out", required=True)
    parser.add_argument("--workspace", default="")
    parser.add_argument("--channel", default="")
    args = parser.parse_args()

    app_path, binary = find_slack()
    was_running = stop_slack(app_path)
    root = tempfile.mkdtemp(prefix="slack-relay-auth.")
    profile = os.path.join(root, "profile")
    proc = None
    try:
        os.chmod(root, 0o700)
        if not os.path.isdir(os.path.join(PROFILE, "Local Storage")):
            raise AuthError(f"Slack has no local session at {PROFILE}; sign in to Slack first")
        note("copying the Slack session")
        shutil.copytree(PROFILE, profile, ignore=IGNORE, symlinks=True)
        port = free_port()
        log_path = os.path.join(root, "slack.log")
        with open(log_path, "wb") as log:
            proc = subprocess.Popen(
                [binary, f"--user-data-dir={profile}", f"--remote-debugging-port={port}",
                 "--remote-debugging-address=127.0.0.1"],
                stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True,
            )
        note("reading the Slack session")
        wait_cdp(port)
        page = wait_page(port)
        ws = WS(page["webSocketDebuggerUrl"])
        try:
            wait_ready(ws)
            teams = read_teams(ws)
            cookies = read_d_cookies(ws)
        finally:
            ws.close()

        sessions = []
        seen = set()
        for team in teams:
            token = team.get("token", "")
            if not token or token in seen:
                continue
            seen.add(token)
            for cookie in cookies:
                body = api("auth.test", {}, token, cookie)
                if body.get("ok"):
                    sessions.append({
                        "name": team.get("name") or body.get("team", ""),
                        "domain": team.get("domain", ""),
                        "team": body.get("team", ""),
                        "url": body.get("url", ""),
                        "user_id": body.get("user_id", ""),
                        "token": token,
                        "cookie": cookie,
                    })
                    break
        if not sessions:
            raise AuthError("Slack's token and cookie did not authenticate; sign in to Slack and rerun")

        if not args.workspace and not args.channel and len(sessions) > 1:
            print(json.dumps({
                "ok": False,
                "error": "multiple_workspaces",
                "workspaces": [workspace_row(item) for item in sessions],
            }))
            sys.exit(2)

        chosen = select(sessions, args.workspace, args.channel)
        write_secret(args.token_out, chosen["token"])
        write_secret(args.cookie_out, chosen["cookie"])
        output = {
            "ok": True,
            "workspace": workspace_row(chosen),
            "workspaces": [workspace_row(item) for item in sessions],
            "token_file": os.path.expanduser(args.token_out),
            "cookie_file": os.path.expanduser(args.cookie_out),
        }
        print(json.dumps(output))
    finally:
        cleanup(proc, profile, app_path, was_running)
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    try:
        main()
    except AuthError as error:
        print(f"slack-relay auth: {error}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)
