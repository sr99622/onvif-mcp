#!/usr/bin/env python3
"""Drive Keycloak login+consent headlessly and deliver the final redirect into the
running `hermes mcp login` loopback callback listener (single-flow isolated run).
Prints status only; never prints credentials or token values."""
import re
import subprocess
import sys
import urllib.parse
import urllib.request
from http.cookiejar import CookieJar

auth_url = sys.argv[1]
username = "mcp-user"
secret = subprocess.run(["sudo", "cat", "/opt/keycloak/mcp-user.pass"],
                        capture_output=True, text=True).stdout.strip()

cj = CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))
opener.addheaders.append(("User-Agent", "onvif-mcp-runbook driver"))


def form_fields(html):
    fields = {}
    for tag in re.findall(r"<input[^>]+>", html, re.S):
        name_m = re.search(r"\bname=(?:\"([^\"]+)\"|'([^']*)')", tag)
        if not name_m:
            continue
        name = name_m.group(1) or name_m.group(2)
        value_m = re.search(r"\bvalue=(?:\"([^\"]*)\"|'([^']*)')", tag)
        fields[name] = (value_m.group(1) or value_m.group(2)) if value_m else ""
    return fields


def parse_action(html):
    m = re.search(r"<form[^>]*\baction=(?:\"([^\"]+)\"|'([^']*)')", html, re.S)
    return (m.group(1) or m.group(2)) if m else None


def post(base, action, fields):
    url = urllib.parse.urljoin(base, action) if not action.startswith("http") else action
    body = urllib.parse.urlencode(fields).encode()
    req = urllib.request.Request(url, data=body,
                                 headers={"Content-Type": "application/x-www-form-urlencoded"})
    return opener.open(req)


page = opener.open(auth_url)
base = page.geturl()
html = page.read().decode(errors="replace")

for step in range(6):
    action = parse_action(html)
    fields = form_fields(html)
    low = html.lower()
    body_start = low.find("<body")
    snippet = low[body_start:body_start + 400] if body_start >= 0 else ""

    if "scope_consent" in low and action:
        print(f"step {step}: consent screen (action={action[:60]}...)")
        resp = post(base, action, fields)
    elif ("login" in snippet or "password" in low) and action:
        print(f"step {step}: login form (action={action[:60]}...)")
        fields["username"] = username
        fields["password"] = secret
        resp = post(base, action, fields)
    else:
        clean = snippet.replace(username, "<u>").replace(secret.lower(), "<pw>")
        print("no recognizable form; page excerpt (sanitized):", clean[:400])
        sys.exit(2)

    base = resp.geturl()
    html = resp.read().decode(errors="replace")
    parsed = urllib.parse.urlparse(base)
    if parsed.hostname in ("127.0.0.1", "localhost"):
        keys = [k for k in urllib.parse.parse_qs(parsed.query)]  # values never printed
        print("callback delivered:", parsed.netloc + parsed.path, "| params:", keys)
        sys.exit(0 if "code" in keys else 4)

print("did not reach callback; last url:", base[:80])
sys.exit(3)
