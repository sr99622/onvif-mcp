#!/usr/bin/env python3
"""Drive Keycloak login + consent with headless Chrome (CDP) and deliver the final
redirect into the running `hermes mcp login` loopback callback listener.

Uses a fresh throwaway Chrome profile with extensions and autofill/password-manager
features disabled, so no saved credentials from an interactive desktop session are
ever used. Credentials come only from the root-owned password file.

Prints status only; never prints credentials, cookies, OAuth codes, state values,
PKCE values, or tokens.
"""
import base64
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

auth_url = sys.argv[1]
username = "mcp-user"
secret = subprocess.run(["sudo", "cat", "/opt/keycloak/mcp-user.pass"],
                        capture_output=True, text=True).stdout.strip()

cdp_port = int(os.environ.get("CDP_PORT", "9333"))
profile_dir = sys.argv[2] if len(sys.argv) > 2 else tempfile.mkdtemp(
    prefix="kc-headless-profile-", dir=os.environ.get("TMPDIR", "/tmp"))


def ws_connect(ws_url):
    p = urllib.parse.urlparse(ws_url)
    sock = socket.create_connection((p.hostname, p.port), timeout=15)
    key = base64.b64encode(os.urandom(16)).decode()
    sock.sendall((f"GET {p.path} HTTP/1.1\r\nHost: {p.netloc}\r\n"
                  "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                  f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        buf += sock.recv(4096)
    if b" 101 " not in buf.split(b"\r\n", 1)[0]:
        raise RuntimeError("CDP websocket handshake failed")
    return sock


def ws_send(sock, obj):
    data = json.dumps(obj).encode()
    mask = os.urandom(4)
    n = len(data)
    if n < 126:
        header = b"\x81" + bytes([0x80 | n])
    elif n < 65536:
        header = b"\x81" + bytes([0x80 | 126]) + struct.pack(">H", n)
    else:
        header = b"\x81" + bytes([0x80 | 127]) + struct.pack(">Q", n)
    sock.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))


def ws_recv(sock, timeout=20):
    sock.settimeout(timeout)

    def readn(n):
        buf = b""
        while len(buf) < n:
            chunk = sock.recv(n - len(buf))
            if not chunk:
                raise RuntimeError("CDP socket closed")
            buf += chunk
        return buf

    hdr = readn(2)
    length = hdr[1] & 0x7F
    if length == 126:
        length = int.from_bytes(readn(2), "big")
    elif length == 127:
        length = int.from_bytes(readn(8), "big")
    try:
        return json.loads(readn(length).decode()) if length else None
    except Exception:
        return None


def call(sock, mid, method, params=None):
    ws_send(sock, {"id": mid, "method": method, "params": params or {}})
    while True:
        msg = ws_recv(sock)
        if msg and msg.get("id") == mid:
            return msg


def evaluate(sock, mid, expression):
    result = call(sock, mid, "Runtime.evaluate", {"expression": expression, "returnByValue": True})
    return ((result.get("result") or {}).get("result") or {}).get("value")


def main():
    chrome = subprocess.Popen([
        "google-chrome",
        "--headless=new",
        "--no-sandbox",
        "--disable-gpu",
        f"--user-data-dir={profile_dir}",
        "--disable-extensions",
        "--disable-component-extensions-with-background-pages",
        "--disable-sync",
        "--disable-features=AutofillServerCommunication,PasswordManagerEnabled",
        "--disable-save-credentials",
        f"--remote-debugging-port={cdp_port}",
        "about:blank",
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    try:
        page = None
        for _ in range(40):
            try:
                targets = json.loads(urllib.request.urlopen(
                    f"http://127.0.0.1:{cdp_port}/json/list", timeout=3).read())
                page = [t for t in targets if t.get("type") == "page"]
                if page:
                    break
            except Exception:
                time.sleep(0.5)
        if not page:
            print("chrome: no CDP page target (extension/autofill pages ignored)")
            return 1

        sock = ws_connect(page[0]["webSocketDebuggerUrl"])
        mid = 0
        mid += 1; call(sock, mid, "Page.enable")
        mid += 1; call(sock, mid, "Runtime.enable")
        mid += 1; call(sock, mid, "Page.navigate", {"url": auth_url})
        time.sleep(3)

        for step in range(8):
            url = evaluate(sock, mid + 1, "location.href") or ""
            parsed = urllib.parse.urlparse(url)
            if url.startswith("chrome-error://"):
                print("chrome error page: navigation failed (certificate not trusted? "
                      "check the NSS trust store ~/.pki/nssdb); not treated as a login form")
                return 5
            if parsed.hostname in ("127.0.0.1", "localhost"):
                keys = list(urllib.parse.parse_qs(parsed.query))  # values never printed
                print("callback delivered:", parsed.netloc + parsed.path, "| params:", keys)
                return 0 if "code" in keys else 4

            html = (evaluate(sock, mid + 1, "document.body ? document.body.innerHTML : ''") or "").lower()
            if "scope_consent" in html or 'name="accept"' in html:
                print(f"step {step}: consent screen")
                evaluate(sock, mid + 1,
                         "(function(){var b=document.querySelector('input[name=accept]')"
                         "||document.querySelector('button[type=submit]');b.click();})()")
            elif evaluate(sock, mid + 1, "!!document.querySelector('input[name=username]')"):
                print(f"step {step}: login form")
                expr = ("(function(){var u=document.querySelector('input[name=username]');"
                        "var p=document.querySelector('input[name=password]');"
                        f"u.value={json.dumps(username)};p.value={json.dumps(secret)};"
                        "u.form.submit();})()")
                evaluate(sock, mid + 1, expr)
            else:
                print("no recognizable form; page host:", parsed.netloc or "(blank)")
                return 2
            time.sleep(3)

        print("did not reach callback")
        return 3
    finally:
        chrome.terminate()


if __name__ == "__main__":
    sys.exit(main())
