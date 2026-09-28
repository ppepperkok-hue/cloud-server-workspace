#!/usr/bin/env bash
# check-disk.sh — check disk usage and warn above a threshold.
#
# Usage:   check-disk.sh [THRESHOLD_PCT]
#   THRESHOLD_PCT defaults to 85.
#
# Prerequisites: df(1), awk(1). Read-only, idempotent, no side effects.
# Risk: none. Safe to run anytime.
#
# Exit codes:
#   0 = all filesystems below threshold
#   1 = at least one filesystem at or above threshold

set -u

THRESHOLD="${1:-85}"

# Use % as the separator so we can split fields cleanly.
df -P | awk -v t="$THRESHOLD" '
  NR == 1 { next }                          # skip header
  {
    use = $5 + 0                            # strip trailing "%"
    if (use >= t) {
      printf "WARN  %-24s %3d%% used (threshold %d%%)\n", $6, use, t
      bad++
    }
  }
  END {
    if (bad) { printf "DISK  %d filesystem(s) at/above threshold\n", bad; exit 1 }
    printf "DISK  all filesystems below %d%%\n", t
  }
'
