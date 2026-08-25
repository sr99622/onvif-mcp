# fix(mcp): stdio fast-fail liveness check inverted — live MCP servers fail every tool call

Everything below was prepared locally. **Update 2026-08-25: this turned out to be a KNOWN upstream issue.**

## Upstream status (checked 2026-08-25)

- **Issue #94335** — open, labeled `type/bug` + `P1`: describes `_stdio_children_dead()`
  inverted liveness verbatim (same code block, same repro, same fix). Filed by
  liuhao1024.
- **PR #94339** — the canonical open fix (unmerged as of today): identical one-line
  change to ours plus a regression test `tests/tools/test_mcp_stdio_children_dead.py`
  with the same assertions as ours (live→False, all-dead→True, mixed→False).
- **PRs #94378 and #94661** — closed today as duplicates in favor of #94339.
  Notable: their authors contributed an "unknown → fail open" contract (missing
  psutil / failed `pid_exists()` probe must NOT authorize the destructive fast-fail)
  offered for absorption into #94339 — worth watching; our patch does not carry it.
- **PRs #94521 and #94586** — still open, same fix (competing carriers).
- Upstream `origin/main` == local commit 1bbb6e5b (v0.20.5); no fix merged yet.

## What this changes about our package

Do NOT file a new issue (#94335 already exists) or open a competing PR. Useful
contributions instead: comment on #94335 with our independent evidence (camera-MCP
contrast, end-to-end proof), offer `prove.py` as a no-deps demonstrator, and track
#94339 for merge — after which `apply.sh` simply becomes unnecessary.

## What's here

| File | Purpose |
|---|---|
| `fix_stdio_children_dead.patch` | The one-hunk fix (16 lines). Applies cleanly to upstream commit 1bbb6e5b (verified with `git apply --check`). Already applied in the local install at `~/.hermes/hermes-agent`. |
| `test_stdio_children_dead.py` | Regression test. Binds the REAL `MCPServerTask._stdio_children_dead` from the installed module (no reimplementation), psutil mocked. 5 assertions. Passes against patched code; 2 of 5 fail against original. |
| `prove-bug/tools/mcp_tool.py` | Verbatim copy of `tools/mcp_tool.py` at upstream commit 1bbb6e5b — for before/after demonstration via `prove.py`. (Contains only this one file: the pytest regression test can't import it standalone because `mcp_tool` has package-level sibling imports; `prove.py` extracts the function via AST, which is why it works against this partial copy. For "pytest fails on original", temporarily place the original over the real `tools/mcp_tool.py` in a checkout.) |
| `prove.py` | Standalone script (no full package tree needed — extracts the function via AST): runs identical assertions against ANY mcp_tool.py. Exit 0 = fixed behavior, exit 1 = regression present. Proves the bug on `prove-bug/` and the fix on the working tree. |
| `ISSUE.md` | Ready-to-file GitHub issue (repro, root cause, evidence). |
| `PR.md` | Ready-to-open PR description. |
| `apply.sh` | Re-applies the fix to a Hermes checkout. Idempotent — run it after any fresh install or `hermes update`. Auto-detects git vs plain layouts; falls back from `git apply` to `patch(1)`. |

## Re-applying after a fresh install / update

The fix is **not** part of upstream and (in this local install) exists only as an
uncommitted working-tree edit. So it does not survive the ways you typically get
Heres fresh code:

- **Fresh install** — a new checkout starts clean, with no local edits at all. The
  patch is simply absent; you apply it afterward.
- **`hermes update` / `git pull` on this install** — by default (`updates.
  non_interactive_local_changes: stash`) Hermes stashes your local edit, pulls, and
  re-applies the stash. That usually survives an update, **but** if upstream ever
  rewrote these same lines, the re-apply conflicts and the fix lands in a git
  `stash` instead of the file — easy to miss.

Either way the safe move is the same: after installing or updating, run

```bash
~/pr-hermes-mcp-stdio-fastfail/apply.sh
# or point it elsewhere:
HERMES_SRC=/path/to/hermes-checkout ~/pr-hermes-mcp-stdio-fastfail/apply.sh
```

It no-ops if already applied, applies cleanly otherwise, and tells you to hand-fix
(if upstream restructured `_stdio_children_dead()` so the hunk no longer matches).
The default target is `~/.hermes/hermes-agent` (a git checkout on this machine —
the launcher runs straight from that tree's venv).

## Repro summary

The fast-fail guard added for #81995 checks whether the stdio MCP child processes
are dead before and during each tool call:

```python
def _stdio_children_dead(self) -> bool:
    ...
    for pid in pids:
        if not psutil.pid_exists(pid):
            continue          # this one is dead
        return True           # BUG: returns "dead" when a child is ALIVE
        return False          # unreachable
    return True
```

`return True` where `return False` belongs: a live tracked PID reports the
server as dead, so **every** tool call on any stdio MCP server raises
`TimeoutError: MCP stdio subprocess for '<name>' has exited; failing the call
fast instead of waiting 300s` — even while the server is running and healthy.

### Evidence collected (2026-08-25)

1. Server health independent of Hermes: `hermes mcp test chrome-devtools` lists all
   29 tools; hand-driving the npx server over stdio (initialize + tools/call) returns
   correct results; the child process tree stays alive (ps shows it, psutil.pid_exists
   true).
2. Same-session failure: `mcp__chrome_devtools__list_pages` fails with "subprocess has
   exited" in a running session; logs show every call fast-failing at 0.00s while the
   spawned child (mcp_stdio_watchdog.py → npx → node) is alive on disk.
3. Function-level proof: executing the shipped `_stdio_children_dead` against live and
   dead PIDs returns True for BOTH — live should return False.
4. Post-patch: identical call in a fresh `hermes chat -q` session succeeds and returns
   the real page list.

### Why it looks intermittent

Only stdio MCP servers are affected, and only when their child PID is tracked and
still alive (which is always true while the server works). HTTP/OAuth MCP servers
(`camera`) bypass this path entirely and work fine in the same session — which is why
the failure appears scoped to specific servers. Any long-running Hermes process that
loaded the buggy module fails all stdio MCP calls until restarted; a fresh process
loads the same code and fails identically (verified today).

## Verification artifacts

- `prove.py prove-bug/tools/mcp_tool.py` → exit 1, 2 FAILs (alive child / mixed)
- `prove.py ~/.hermes/hermes-agent/tools/mcp_tool.py` → exit 0, 5 PASS
- `pytest test_stdio_children_dead.py` (against patched installed module) → 5 passed
- End-to-end: fresh `hermes chat -q` session calling `mcp__chrome_devtools__list_pages`
  returns the live page list, no error.

## Before publishing

- Run in a clean checkout of upstream main (this install is at commit 1bbb6e5b, v0.20.5).
- Optional: run any existing MCP test suite in `tests/` (there's no dedicated
  `_stdio_children_dead` test upstream — that gap is part of why this shipped).
- Decide: file issue only, or issue + PR with the regression test included.
