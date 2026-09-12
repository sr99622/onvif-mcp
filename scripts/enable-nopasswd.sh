#!/usr/bin/env bash
set -euo pipefail

: "${USER:?USER environment variable is not set}"

# Prevent unsafe usernames from affecting the filename or sudoers syntax.
if [[ ! "$USER" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]]; then
    echo "Invalid USER value: $USER" >&2
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "Run this script as root while preserving the intended USER value." >&2
    echo "Example: sudo env USER=\"$USER\" \"$0\"" >&2
    exit 1
fi

sudoers_file="/etc/sudoers.d/${USER}-nopasswd"
temp_file="$(mktemp)"

trap 'rm -f "$temp_file"' EXIT

printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$USER" > "$temp_file"
chmod 0440 "$temp_file"

# Validate the rule before installing it.
visudo -cf "$temp_file"
install -o root -g root -m 0440 "$temp_file" "$sudoers_file"

echo "Created $sudoers_file"