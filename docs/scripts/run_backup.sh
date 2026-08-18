#!/bin/bash
set -o pipefail
tar -C "/Users/stephen/Private-CA" -czf - camera-system-ca | age --passphrase -o "/Users/stephen/Private-CA/backups/camera-system-ca-after-gmktec-cert-2026-08-18.tar.gz.age"
