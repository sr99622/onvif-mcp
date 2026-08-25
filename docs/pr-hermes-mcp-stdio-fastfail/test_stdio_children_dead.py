"""Regression test: MCPServerTask._stdio_children_dead() liveness logic.

Bug (reported 2026-08, Hermes v0.20.5 @ upstream 1bbb6e5b): the fast-fail
liveness check used by every stdio MCP tool call returned True ("dead") when a
tracked child PID was ALIVE — an inverted `return True` with an unreachable
second return. Result: ANY live stdio MCP server tripped

    "MCP stdio subprocess for '<name>' has exited; failing the call fast..."

on every tools/call, even though the server process was running fine and
`hermes mcp test <server>` succeeded.

The test binds the REAL method from tools.mcp_tool (no reimplementation) with a
mocked psutil.pid_exists, exercising the exact production decision:

    if not psutil.pid_exists(pid): continue   # this one is dead
    return False                               # alive => NOT dead   (was: True!)
return True                                    # every child dead => dead

Run from the repo root:  pytest -q <this-file>
(No conftest/rootdir assumption beyond `import tools.mcp_tool` resolving — i.e.
run with the repo root on sys.path, as `python -m pytest` from the root does.)
"""

import sys
from types import SimpleNamespace
from unittest.mock import MagicMock

# Import the real module (repo root must be importable).
import tools.mcp_tool as m  # noqa: E402
from tools.mcp_tool import MCPServerTask  # noqa: E402


def _dead(live_pids, pids=None, http=False):
    """Call the real method with psutil.pid_exists mocked to `live_pids`."""
    s = SimpleNamespace()
    s._is_http = lambda: http
    s._stdio_child_pids = set(pids if pids is not None else live_pids)
    mock_psutil = MagicMock()
    mock_psutil.pid_exists.side_effect = lambda pid: pid in live_pids
    # The function runs `import psutil` inside its body, which rebinds the name
    # from sys.modules — so patch sys.modules itself, not m.psutil.
    real = sys.modules.get("psutil")
    sys.modules["psutil"] = mock_psutil
    try:
        return MCPServerTask._stdio_children_dead(s)
    finally:
        if real is not None:
            sys.modules["psutil"] = real
        else:
            sys.modules.pop("psutil", None)


def test_alive_child_is_not_dead():
    # THE regression: a live tracked PID must not be reported dead.
    assert _dead({12345}) is False


def test_mixed_alive_and_dead_not_dead():
    # one survivor out of several => not "every child exited"
    assert _dead({987654321, 12345}) is False


def test_all_tracked_pids_dead_is_dead():
    # pids non-empty and every one reported dead by psutil => True
    assert _dead(set(), pids={987654321}) is True


def test_empty_pid_set_does_not_fast_fail():
    # no tracked PIDs (unknown) => don't fail fast
    assert _dead(set()) is False


def test_http_server_does_not_fast_fail():
    # HTTP transport: liveness check must never apply
    assert _dead({12345}, pids={12345}, http=True) is False
