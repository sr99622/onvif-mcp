#!/bin/bash
# usage: run_backup.sh [output-age-archive]
#
# Encrypts the camera-system-ca CA state into an age archive, non-interactively.
#
# Delegates to backup_ca.expect because this age build demands a tty for its
# passphrase even when reading it from stdin ("standard input is not a
# terminal, and /dev/tty is not available") — a plain shell cannot supply that.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec expect "$script_dir/backup_ca.expect" "$@"
