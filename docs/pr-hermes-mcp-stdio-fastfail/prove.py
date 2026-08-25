#!/usr/bin/env python3
"""Prove bug + fix without needing the full Hermes package tree.

Extracts MCPServerTask._stdio_children_dead from a given mcp_tool.py via AST
and runs identical assertions against it (psutil mocked).

Usage: prove.py <path-to-mcp_tool.py>
Exit 0 = all assertions hold (fixed behavior), exit 1 = regression present.
"""
import ast
import sys
from types import SimpleNamespace
from unittest.mock import MagicMock

path = sys.argv[1] if len(sys.argv) > 1 else "tools/mcp_tool.py"
src = open(path).read()

tree = ast.parse(src)
fn_src = None
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and node.name == "MCPServerTask":
        for item in node.body:
            if isinstance(item, ast.FunctionDef) and item.name == "_stdio_children_dead":
                fn_src = ast.get_source_segment(src, item)
if not fn_src:
    sys.exit("function not found in " + path)

# Un-indent to module level so it can be exec'd standalone.
import textwrap
ns = {}
exec(compile(textwrap.dedent(fn_src), path, "exec"), ns)
_dead = ns["_stdio_children_dead"]

FAILURES = []


def run(live_pids, pids=None, http=False):
    s = SimpleNamespace()
    s._is_http = lambda: http
    s._stdio_child_pids = set(pids if pids is not None else live_pids)
    mock_psutil = MagicMock()
    mock_psutil.pid_exists.side_effect = lambda pid: pid in live_pids
    # The function runs `import psutil` inside its body; the import rebinds the
    # name from sys.modules, so patch sys.modules itself.
    real = sys.modules.get("psutil")
    sys.modules["psutil"] = mock_psutil
    try:
        return _dead(s)
    finally:
        if real is not None:
            sys.modules["psutil"] = real
        else:
            sys.modules.pop("psutil", None)


def check(name, actual, expected):
    ok = actual is expected
    print(f"  {'PASS' if ok else 'FAIL'}  {name}: got {actual}, want {expected}")
    if not ok:
        FAILURES.append(name)


print(f"mcp_tool.py under test: {path}")
check("alive child is NOT dead", run({12345}), False)
check("mixed (1 alive) is NOT dead", run({987654321, 12345}), False)
check("all tracked dead IS dead", run(set(), pids={987654321}), True)
check("empty pid set does not fast-fail", run(set()), False)
check("HTTP transport never fast-fails", run({12345}, http=True), False)

print()
if FAILURES:
    print(f"REGRESSION PRESENT ({len(FAILURES)} failing): {', '.join(FAILURES)}")
    sys.exit(1)
print("all assertions hold — behavior correct")
sys.exit(0)
