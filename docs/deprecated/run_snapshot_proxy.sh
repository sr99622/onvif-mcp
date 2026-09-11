#!/usr/bin/env bash
# Launch the snapshot proxy fully detached; print readiness once it's listening.
cd /home/stephen/onvif-mcp || exit 1
SNAPSHOT_PROXY_PORT="${SNAPSHOT_PROXY_PORT:-8891}" python3 services/snapshot_proxy.py
