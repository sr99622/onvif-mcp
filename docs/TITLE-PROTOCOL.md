# Tab-title observability for camera stream loads

Date: 2026-08-27 (supersedes PLAYWRIGHT.md — that doc is kept as history).
Tools live in `/home/stephen/bin/`: `cdpnav`, `camwatch`, `camlib.py` (shared raw-CDP plumbing). All stdlib-only Python.

## The one idea

**The browser's own tab title tells you how a stream load turned out — and it persists.**

The WebRTC relay (gmktec.home.arpa, behind the oauth2 proxy) renders failed loads
as Chrome error pages whose **title is the HTTP status itself**:
`500 Internal Server Error`. A healthy stream page sets *no* `<title>`, so the
tab title falls back to the bare URL (`gmktec.home.arpa/webrtc/<serial>/<profile>/`).
An auth wall bounces the tab onto the Keycloak login path (recognizable in
title/url). Reading the title once per load — a single GET on `/json/list` — is a
**complete, after-the-fact, zero-subscription** observation of "did that render".

Verified empirically (this machine, 2026-08-27):

| Rendered state | Observed tab title | Source |
|---|---|---|
| token-expiry 500 (first paint) | `500 Internal Server Error` | read after the fact via CDP `/json/list` AND Hyprland's `initialTitle` survived a full Chromium restart |
| healthy stream page | bare webrtc URL (no `<title>` in MediaMTX player HTML; in-page fetch = 200) | same |
| session fully expired | Keycloak auth path (title+url contain `/auth/realms/`, `oauth`) | curl probe: unauthenticated → 302 to Keycloak login |

## Why this replaces the Playwright mechanism

The old design (PLAYWRIGHT.md) observed loads via network `response` events,
which are **live-only**: subscribe before the load or that status is gone
forever. Everything else followed from that rule — a resident daemon required
to witness loads, present-tense re-fetches that re-authenticate as they run and
cannot show a 500 seconds old, stale cached page handles after external
navigations (the `page.reload()` "Not attached" pitfall), Playwright resolution
across install trees.

A tab title has none of those failure modes:

- **Persists** until the next load — observation works *after the fact* with no
  subscription and no replay rule.
- **No dependency**: `chromium --remote-debugging-port=9222` + a GET on
  `/json/list` (the field you already see in the taskbar / Hyprland).
- **Catches what events missed**: a brand-new tab that opens onto an error page
  is visible immediately — the target exists before its load completes, and the
  title is set as it renders.
- Actuation (reload) stays on the proven raw-CDP path (fresh WebSocket to the
  tab's `webSocketDebuggerUrl`), which never hits stale-handle problems.

## The three-state discriminator

```
state = 'error'    title matches ^\d{3}\b and contains "Error"   -> code IS the HTTP status
state = 'auth'     title/url on Keycloak oauth path              -> user must log in; reload won't fix it
state = 'ok'       anything else (bare webrtc URL / player title)-> healthy render
```

## cdpnav — navigate + observe in one call

`cdpnav <url>`: Page.enable → Page.navigate on the camera tab → **block on
Page.loadEventFired** (no blind sleep) → settle 1s → read `/json/list` → classify.

- healthy → prints `load initial: ok`, exit 0
- error title → AUTO-RELOADS once (token re-auth), waits, re-reads, reports both:
  `load initial: error (500)` / `load re-auth reload: ok`, exit 0 when recovered
- auth wall → prints it and exits 1 (reload won't help without a login)
- `--no-reload` disables self-heal (observe only; let camwatch heal)

Field result: on an already-expired token, one call produced exactly
`error (500)` → `re-auth reload: ok`.

## camwatch — resident title poller + auto-healer daemon

Replaces pw_watch. Polls `/json/list` at 1 Hz; for each camera tab reads the
title and logs **state transitions only** (keeps the log readable):

```
<ts>Z tab-open ok (url)          # first time this tab is seen (catches fresh-error tabs)
<ts>Z error 500 url              # a load rendered an error page
<ts>Z AUTO-HEAL reloading (500) url   # raw-CDP reload in-process (≤1 per tab per 5s)
<ts>Z ok url                     # recovery confirmed (title back to healthy)
<ts>Z SESSION attach ok / connection lost / stop
```

Measured: injected `500 Internal Server Error` title → transition logged →
AUTO-HEAL reload → recovery line **1 second later**. Because the title is read
passively, camwatch also witnesses loads it didn't trigger — cdpnav's and your
own F5s alike.

Operational notes (unchanged contract from pw_watch):

- Log `~/.hermes/camera-loads.log` · pid `~/.hermes/camera-watch.pid` · out
  `~/.hermes/camera-watch.out`. `camwatch start|stop|status`, `--foreground`,
  `--no-auto-reload`.
- **Browser restart kills it** (connection lost after ~6 failed polls, exit 3).
  After relaunching Chromium: `camwatch status` then `camwatch start`.
- Transition-only log means "what happened to the tab" — not a per-response
  audit of every sub-resource (that was pw_watch's `--all`; retired).

## Decision guide

- Switch cameras fast → `cdpnav <url>` (now also reports its own result; no
  separate verification needed).
- "Did that render?" after the fact → `camwatch status` / tail the log.
- User reports an error on screen → reload once via cdpnav without asking; the
  log shows the error + recovery pair.
- Need a raw, unhealed observation (debugging) → `cdpnav <url> --no-reload`,
  with camwatch in `--no-auto-reload` if you must not self-heal.

## History

PLAYWRIGHT.md (kept as-is) documents the superseded Playwright/response-event
mechanism, its field failures, and why it was retired. The raw-CDP actuation
lessons there are still true: act through fresh per-command WebSockets, and
retry around mid-reload target-list races (both implemented in camlib.py).
