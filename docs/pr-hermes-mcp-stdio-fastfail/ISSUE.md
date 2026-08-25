# stdio MCP tool calls fail fast with "subprocess has exited" for a HEALTHY server

**Version:** v0.20.5 (commit 1bbb6e5b, 2026-08-19)
**Component:** `tools/mcp_tool.py` → `MCPServerTask._stdio_children_dead()`

## Symptom

Every tool call against a **stdio** MCP server fails with:

```
MCP stdio subprocess for '<name>' has exited; failing the call fast
instead of waiting 300s
```

even though the MCP server subprocess is running and healthy. HTTP/OAuth MCP
servers in the same session work fine, so it looks scoped to specific servers.

## Reproduction

1. Configure a stdio MCP server (any — e.g. `npx chrome-devtools-mcp@latest`).
2. Verify it's healthy independently:
   - `hermes mcp test <server>` → lists all tools ✓
   - Hand-drive it over stdio (`initialize` + `tools/call`) → correct result ✓
   - The spawned child process is alive on disk (`ps`, `psutil.pid_exists` true) ✓
3. Call any of its tools from a Hermes session → **fails** with the "has exited" error above, at 0.00s.

The same call in a fresh `hermes chat -q` process fails identically (same code), so it is deterministic for stdio servers, not transient.

## Root cause

The fast-fail guard introduced for #81995 (`_stdio_children_dead`, ~line 2990)
has an inverted liveness check:

```python
for pid in pids:
    if not psutil.pid_exists(pid):
        continue          # this one is dead — correct
    return True           # BUG: returns "dead" when a child is ALIVE
    return False          # unreachable (dead code)
return True               # all dead — correct
```

`return True` where `return False` belongs. Any tracked child PID that is still
alive makes the method report the server as **dead**, so the fast-fail path trips
on every call while the server is actually running. Because a live server always
has at least one live PID, the check is effectively "always dead" whenever PIDs
are tracked — defeating its own purpose (failing fast on a genuinely-dead child).

Executing the shipped function against real live and dead PIDs confirms it returns
`True` for both:

```
LIVE pids  -> dead? True   (correct is False)
DEAD pids  -> dead? True   (correct is True)
EMPTY      -> dead? False  (correct is False)
```

## Fix

One line — return `False` when a tracked child is still alive:

```python
for pid in pids:
    if not psutil.pid_exists(pid):
        continue          # this one is dead
    return False          # at least one child alive — don't fast-fail
return True               # every tracked child has exited
```

## Why it shipped

`tests/` has no dedicated test for `_stdio_children_dead` / the stdio fast-fail
path, so the inverted branch was not caught. The `#81995` intent (fail fast when
the child genuinely died) is preserved by the fix — the guard now only trips when
**every** tracked PID is dead.

## Verification

- Standalone proof script runs identical assertions against a copy of
  `mcp_tool.py` at 1bbb6e5b and against the patched tree:
  - original → 2 FAIL (alive child, mixed)
  - patched → 5 PASS
- Regression test binds the real method from the installed module: 5 passed on
  patched code.
- End-to-end: fresh `hermes chat -q` session calling a live stdio MCP tool now
  succeeds and returns the real result; no "has exited" error.

## Workaround (until fixed)

Restart Hermes after any clean shutdown, or use an HTTP transport for the server.
Long-running processes that loaded the buggy module will fast-fail all stdio calls
regardless of server health.
