# Fix for Camera MCP Stdio Transport on Fresh Hermes Installs

## Problem

On a fresh install of Hermes Agent, the camera MCP server fails to start with an ENOENT error when using the stdio transport. The root cause is in `tools/mcp_tool.py`, specifically the `_resolve_stdio_command()` function.

When Hermes spawns an MCP server subprocess, it uses a **filtered sandbox PATH** for security - only essential system directories are included. The `_resolve_stdio_command()` function has a fallback chain that manually resolves known commands to their absolute paths when they're not found on the filtered PATH.

The default code only knows about `npx`, `npm`, and `node`. When your MCP config uses `command: uv` (which is how this camera server is configured), Hermes tries to run `uv` from the sandboxed PATH, doesn't find it, and the subprocess dies with ENOENT.

## The Fix

Two changes are needed in `tools/mcp_tool.py`:

### Change 1 - Add `"uv"` to the fallback set (around line 716)

Find this line:
```python
        elif resolved_command in {"npx", "npm", "node"}:
```

Change it to:
```python
        elif resolved_command in {"npx", "npm", "node", "uv"}:
```

### Change 2 - Add `~/.hermes/bin/` to the candidate search paths (around line 723)

Find this block:
```python
            candidates = [
                os.path.join(hermes_home, "node", "bin", resolved_command),
                os.path.join(os.path.expanduser("~"), ".local", "bin", resolved_command),
```

Insert a new candidate after `node/bin`:
```python
            candidates = [
                os.path.join(hermes_home, "node", "bin", resolved_command),
                # uv (uvx) is installed by Hermes at ~/.hermes/bin/ via the
                # installer script - not in node/bin.  Also check the common
                # user-install and system-wide locations.
                os.path.join(hermes_home, "bin", resolved_command),
                os.path.join(os.path.expanduser("~"), ".local", "bin", resolved_command),
```

## How to Apply on a Fresh Install

### Option A - Apply with sed + manual edit (no network needed)

1. **Add uv to the set:**
   ```bash
   cd ~/.hermes/hermes-agent
   sed -i 's/elif resolved_command in {"npx", "npm", "node"}:/elif resolved_command in {"npx", "npm", "node", "uv"}:/' tools/mcp_tool.py
   ```

2. **Add the `~/.hermes/bin/` fallback:**
   Open `tools/mcp_tool.py` in your editor and find the `candidates = [` block (search for `"node", "bin"`). Insert this line right after the `node/bin` line:
   ```python
                   os.path.join(hermes_home, "bin", resolved_command),
   ```

### Option B - Copy from an already-fixed install

If you have access to a machine with an already-patched Hermes Agent install:
```bash
scp /home/stephen/.hermes/hermes-agent/tools/mcp_tool.py \
    user@new-host:/tmp/mcp_tool.py.new

# On the new host, back up and replace:
cp ~/.hermes/hermes-agent/tools/mcp_tool.py \
   ~/.hermes/hermes-agent/tools/mcp_tool.py.bak
cp /tmp/mcp_tool.py.new \
   ~/.hermes/hermes-agent/tools/mcp_tool.py
```

### Option C - Apply with the patch tool (if using Hermes Agent to apply)

Run a single `sed` for both changes. The exact line numbers may vary slightly depending on your install version - check that the old_string matches what's actually in your file before patching.

## Verify the Fix

1. Restart Hermes Agent after making the change.
2. Run a test camera command: `mcp__cameras__get_cameras`
3. You should see the list of discovered cameras on your network (no ENOENT errors).

## Why This Happens

The camera MCP server config looks like this in `config.yaml`:

```yaml
mcp_servers:
  cameras:
    command: uv          # <-- THIS is what breaks without the fix
    args:
      - "--directory"
      - "/path/to/onvif-mcp/packages/stdio/src"
      - "run"
      - "camera.py"
    enabled: true
```

When Hermes spawns this subprocess, it sets a sandboxed PATH that only contains system directories. The `uv` binary lives at `~/.hermes/bin/uv` (installed by the Hermes installer) and also possibly at `~/.local/bin/uv` or `/usr/local/bin/uv`. Without the fix in `_resolve_stdio_command()`, Hermes can't resolve `uv` to an absolute path inside the sandbox, so the subprocess call fails before it even starts.
