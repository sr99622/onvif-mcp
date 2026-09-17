#!/usr/bin/env python3
"""STREAM_AUTH.md Phase 9 driver: agent-driven headless verification of the
oauth2-proxy browser login flow and snapshot gating. In-memory cookie jars
only; asserts status codes, parameter NAMES (never values), landing paths, and
JPEG magic bytes. Never prints credentials, tokens, code/state values, or
cookies; never persists cookies to disk.

The public --origin is required: never submit a local deployment's password to
an inherited example hostname. Other deployment-specific values are parameters.
Run from the repository root:

    python3 scripts/stream_auth_step9_driver.py --origin https://SERVER_FQDN [--options]

The password is read by the driver itself from --password-file inside this one
process; it must not be copied into chat, documentation, or a command line.
"""
import argparse
import re
import ssl
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from http.cookiejar import CookieJar

UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0 Safari/537.36")


class NoRedir(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None  # raise HTTPError so the caller reads the 3xx itself


def make_opener(jar, follow=True):
    ctx = ssl.create_default_context()
    handlers = [urllib.request.HTTPSHandler(context=ctx),
                urllib.request.HTTPCookieProcessor(jar)]
    if not follow:
        handlers.append(NoRedir)
    op = urllib.request.build_opener(*handlers)
    op.addheaders.append(("User-Agent", UA))
    return op


def parse_form(html):
    fields = {}
    for m in re.finditer(r"<(input|select)\b[^>]*>", html, re.S):
        tag = m.group(0)
        nm = re.search(r"\bname=(?:\"([^\"]+)\"|'([^']*)')", tag)
        if not nm:
            continue
        name = nm.group(1) or nm.group(2)
        if name in fields:
            continue
        if m.group(1) == "select":
            sel = (re.search(r"<option\b[^>]*\bselected\b[^>]*>\s*([^<]*)", tag, re.S)
                   or re.search(r"<option\b[^>]*value=\"([^\"]*)\"", tag))
            fields[name] = (sel.group(1).strip() if sel and sel.group(1) is not None else "")
        else:
            # Hidden inputs without a value attribute exist in the login form;
            # default them to "" — naive group fallbacks crash on the first one.
            vm = re.search(r"\bvalue=(?:\"([^\"]*)\"|'([^']*)')", tag)
            if vm is None:
                fields[name] = ""
            elif vm.group(1) is not None:
                fields[name] = vm.group(1)
            else:
                fields[name] = vm.group(2) or ""
    return fields


def form_action(html):
    m = re.search(r"<form[^>]*\baction=(?:\"([^\"]+)\"|'([^']*)')", html, re.S)
    return (m.group(1) or m.group(2)) if m else None


def first_hop(opener_nofollow, url):
    """Return (status, location, body) for a single request; 3xx NOT followed."""
    try:
        r = opener_nofollow.open(urllib.request.Request(url))
        return r.status, r.headers.get("Location") or "", r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.headers.get("Location") or "", e.read()


def follow_login(opener, start_url, username, secret):
    url = start_url
    for step in range(10):
        try:
            resp = opener.open(urllib.request.Request(url))
        except urllib.error.HTTPError as e:
            print(f"    hop{step}: terminal error status={e.code} at "
                  f"{urllib.parse.urlsplit(e.geturl()).path}")
            return e, url
        url = resp.geturl()
        body = resp.read().decode(errors="replace")
        low = body.lower()
        action = form_action(body)
        fields = parse_form(body)
        names = sorted(fields)
        if "scope_consent" in low and action:
            print(f"    hop{step}: consent screen, field names={names}")
            data = urllib.parse.urlencode(fields).encode()
            try:
                r = opener.open(urllib.request.Request(
                    urllib.parse.urljoin(url, action), data=data,
                    headers={"Content-Type": "application/x-www-form-urlencoded"}))
            except urllib.error.HTTPError as e:
                print(f"    hop{step}: consent post error status={e.code}")
                return e, url
            url = r.geturl()
        elif (("password" in names or ("username" in names and "credentialId" in low))
              and action):
            print(f"    hop{step}: login form, field names={names}")
            fields["username"] = username
            fields["password"] = secret
            data = urllib.parse.urlencode(fields).encode()
            try:
                r = opener.open(urllib.request.Request(
                    urllib.parse.urljoin(url, action), data=data,
                    headers={"Content-Type": "application/x-www-form-urlencoded"}))
            except urllib.error.HTTPError as e:
                print(f"    hop{step}: login post error status={e.code}")
                return e, url
            url = r.geturl()
        else:
            print(f"    hop{step}: settled at path={urllib.parse.urlsplit(url).path} "
                  f"status={resp.status}")
            return resp, url
    raise SystemExit("failed: no terminal page within 10 hops")


def is_jpeg(body):
    return body[:3] == bytes.fromhex("ffd8ff")


def main():
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--origin", required=True,
                   help="public HTTPS origin ({{SERVER_FQDN}} with scheme)")
    p.add_argument("--target", default="/cameras/",
                   help="protected app route to land on after login")
    p.add_argument("--second-route", default="/multiview/",
                   help="second protected route checked in the same session")
    p.add_argument("--snapshot-path",
                   default="/snapshot/4B0013BPAABE264/MediaProfile000/",
                   help="known direct snapshot path ({{SNAPSHOT_PATH}})")
    p.add_argument("--webrtc-url", default="/webrtc/ND021810001394/MediaProfile000/",
                   help="known direct WebRTC stream URL under /webrtc/.../")
    p.add_argument("--realm", default="mcp", help="Keycloak realm ({{MCP_REALM}})")
    p.add_argument("--username", default="mcp-user",
                   help="browser login user ({{MCP_LOGIN_USER}})")
    p.add_argument("--password-file", default="/opt/keycloak/mcp-user.pass",
                   help="root-readable file containing the login password")
    a = p.parse_args()

    # Password read inside this one process only; never on argv or in output.
    secret = subprocess.run(["sudo", "cat", a.password_file],
                            capture_output=True, text=True).stdout.strip()
    if not secret:
        raise SystemExit(f"failed: empty password from {a.password_file}")

    print(f"== S1: unauthenticated {a.target} must be a login redirect ==")
    j1 = CookieJar()
    st1, loc1, _ = first_hop(make_opener(j1, follow=False), a.origin + a.target)
    u1 = urllib.parse.urlsplit(loc1)
    rd_ok = (f"rd={a.target}" in loc1) or \
        urllib.parse.parse_qs(u1.query).get("rd") == [a.target]
    print(f"    status={st1} path={u1.path} rd_is_target={rd_ok}")
    assert st1 == 302 and "oauth2/start" in u1.path, f"S1 fail: {st1} {loc1}"
    assert rd_ok, f"S1 rd mismatch: {loc1}"

    print("== S2: /oauth2/start one hop -> Keycloak authorize with PKCE names ==")
    j2 = CookieJar()
    st2, loc2, _ = first_hop(make_opener(j2, follow=False),
                             a.origin + "/oauth2/start?rd=" + urllib.parse.quote(a.target))
    u2 = urllib.parse.urlsplit(loc2)
    q2 = urllib.parse.parse_qs(u2.query)
    need = {"client_id", "redirect_uri", "response_type", "scope",
            "state", "code_challenge", "code_challenge_method"}
    missing = need - set(q2)
    print(f"    status={st2} host={u2.netloc} path={u2.path}")
    print(f"    param names present: {sorted(q2.keys())}")
    assert st2 == 302, f"S2 status {st2}"
    assert not missing, f"S2 missing params: {missing}"
    assert q2.get("code_challenge_method") == ["S256"], "S2 PKCE method not S256"
    assert u2.netloc == urllib.parse.urlsplit(a.origin).netloc \
        and f"/auth/realms/{a.realm}/" in u2.path \
        and u2.path.endswith("/protocol/openid-connect/auth"), f"S2 wrong target: {u2.path}"

    print(f"== S3/S4: session completes login, lands EXACTLY on {a.target} ==")
    jB = CookieJar()
    oB = make_opener(jB, follow=True)
    respB, urlB = follow_login(oB, a.origin + "/oauth2/start?rd=" + urllib.parse.quote(a.target),
                               a.username, secret)
    uB = urllib.parse.urlsplit(urlB)
    ctype_b = respB.headers.get("Content-Type") or ""
    print(f"    landed path={uB.path} status={getattr(respB, 'status', None)} "
          f"content-type={ctype_b!r}")
    assert uB.path == a.target, f"S3/S4 wrong landing: {urlB}"
    assert respB.status == 200 and "text/html" in ctype_b.lower(), \
        f"S3 fail: status={getattr(respB, 'status', None)} ct={ctype_b!r}"

    print("== S-ping: authenticated /oauth2/ping must be 202 'Authenticated' ==")
    rp = oB.open(urllib.request.Request(a.origin + "/oauth2/ping"))
    ping_body = rp.read().decode(errors="replace")
    print(f"    status={rp.status} body={ping_body!r}")
    assert rp.status == 202 and ping_body.strip() == "Authenticated", \
        f"ping fail: {rp.status} {ping_body!r}"

    print(f"== S4: {a.second_route} same session, no second login ==")
    rm = oB.open(urllib.request.Request(a.origin + a.second_route))
    ctm = rm.headers.get("Content-Type") or ""
    body_m = rm.read()
    bounced = "oauth2/start" in (rm.headers.get("Location") or "")
    print(f"    status={rm.status} content-type={ctm!r} size={len(body_m)} "
          f"login_bounce={bounced}")
    assert rm.status == 200 and "text/html" in ctm.lower() and not bounced, \
        f"S4 fail: {rm.status} {ctm!r}"

    print("== S5/S6: WebRTC pass-through (any non-signin-bounce outcome) ==")
    rw = oB.open(urllib.request.Request(a.origin + a.webrtc_url))
    locw = rw.headers.get("Location") or ""
    body_w = rw.read()
    web_bounced = "oauth2/start" in locw or "/auth/realms/" in locw
    print(f"    status={rw.status} location={locw[:100]!r} "
          f"content-type={rw.headers.get('Content-Type')!r}")
    assert not web_bounced, f"S6 bounced to sign-in: {locw!r}"

    print("== S7: snapshot same session -> real JPEG + no-store, no second login ==")
    rs = oB.open(urllib.request.Request(a.origin + a.snapshot_path))
    bys = rs.read()
    cts = rs.headers.get("Content-Type") or ""
    ccs = (rs.headers.get("Cache-Control") or "").lower()
    print(f"    status={rs.status} content-type={cts!r} cache-control={ccs!r} "
          f"jpeg_magic={is_jpeg(bys)} size={len(bys)}")
    assert rs.status == 200 and "image/jpeg" in cts.lower(), f"S7 fail: {rs.status} {cts!r}"
    assert is_jpeg(bys), "S7 body not JPEG"
    assert "no-store" in ccs, f"S7 cache-control={ccs!r}"

    print("== S8: FRESH unauthenticated session, direct snapshot URL, then login ==")
    jC = CookieJar()
    oCnf = make_opener(jC, follow=False)
    st8, loc8, _ = first_hop(oCnf, a.origin + a.snapshot_path)
    u8 = urllib.parse.urlsplit(loc8)
    rd_has_target = "snapshot" in loc8 and \
        (urllib.parse.parse_qs(u8.query).get("rd") == [a.snapshot_path] or
         a.snapshot_path in loc8)
    print(f"    unauth status={st8} path={u8.path} rd_contains_snapshot={rd_has_target}")
    assert st8 == 302 and "oauth2/start" in u8.path and rd_has_target, \
        f"S8a fail: {st8} {loc8}"
    oC = make_opener(jC, follow=True)  # same jar C, now following redirects
    resp8, url8 = follow_login(oC, a.origin + u8.path + "?" + u8.query, a.username, secret)
    u8b = urllib.parse.urlsplit(url8)
    print(f"    landed path={u8b.path} status={getattr(resp8, 'status', None)}")
    assert u8b.path == a.snapshot_path, f"S8 did not return to requested snapshot: {url8}"
    r8 = oC.open(urllib.request.Request(a.origin + a.snapshot_path))
    by8 = r8.read()
    ct8 = r8.headers.get("Content-Type") or ""
    cc8 = (r8.headers.get("Cache-Control") or "").lower()
    print(f"    image status={r8.status} content-type={ct8!r} cache-control={cc8!r} "
          f"jpeg_magic={is_jpeg(by8)} size={len(by8)}")
    assert r8.status == 200 and "image/jpeg" in ct8.lower() \
        and is_jpeg(by8) and "no-store" in cc8, "S8 image fail"

    print("\nRESULT=PASS (browser sessions via scripted headless flow; "
          "live video render is human-only)")


if __name__ == "__main__":
    main()
