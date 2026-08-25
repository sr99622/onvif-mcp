# fix(mcp): correct inverted liveness check that fast-failed healthy stdio MCP servers

## Problem

The fast-fail guard for #81995 — `MCPServerTask._stdio_children_dead()` in
`tools/mcp_tool.py` — returned `True` ("server dead") when a tracked child PID was
**alive**:

```python
for pid in pids:
    if not psutil.pid_exists(pid):
        continue
    return True    # BUG: "dead" while a child is alive; the line below is unreachable
    return False   # unreachable
return True
```

Net effect: every tool call on any live **stdio** MCP server raised
`TimeoutError: ... subprocess for '<name>' has exited; failing the call fast...`
while the server was running and healthy. A live server always has a live PID, so
the guard fired unconditionally — defeating its own purpose (fail-fast on a truly
dead child). HTTP/OAuth servers are unaffected (guarded by `_is_http()`), which is
why the failure appeared scoped to specific servers.

## Change

Single line: return `False` when at least one tracked child is still alive; only
return `True` when every tracked PID has exited. The #81995 intent (fail fast when
the child genuinely died) is preserved — the guard now trips exactly when all PIDs
are dead.

```diff
-            return True  # alive (signal permission irrelevant for liveness)
-            return False  # at least one child alive
-        return True
+            return False  # at least one child alive — don't fast-fail
+        return True  # every tracked child has exited
```

Plus a regression test that binds the **real** method from the installed module
(psutil mocked) and asserts the four decision branches.

## Testing

- New `test_stdio_children_dead.py` exercises `MCPServerTask._stdio_children_dead`
  directly: alive → False, mixed (one survivor) → False, all-dead → True, empty
  pid set → False (unknown ⇒ don't fail fast), HTTP transport → False. **5 passed.**
- The same assertions run against a verbatim copy of `mcp_tool.py` at the pre-fix
  commit: **2 fail** (the alive/mixed cases), proving the test catches this exact bug.
- End-to-end: a fresh Hermes session calling a live stdio MCP tool (`list_pages`)
  now succeeds and returns the real result; previously it failed at 0.00s with the
  "has exited" error while the child process was confirmed alive on disk.

## Notes

- No API or behavior change beyond correcting the boolean; the unreachable second
  return is removed as part of the fix.
- Does not alter `_watch_stdio_children` (in-flight polling) — it simply now polls a
  correct liveness predicate.
- Local install verified: `git apply --check` clean on upstream 1bbb6e5b; the only
  modified file is `tools/mcp_tool.py`.
