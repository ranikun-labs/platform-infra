#!/bin/sh
# shellcheck disable=SC2034 # variables below are used by the scripts that source this file
# Shared helpers for the Carelog TLS candidate tests. Sourced, not executed.
# Every test prints one line per check: "PASS <name>" or "FAIL <name>" (+ a reason line).
# Nothing generated is written into the repository: material lives in a mktemp directory.
export MSYS_NO_PATHCONV=1
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
CANDIDATE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
PASS_N=0
FAIL_N=0

pass() { PASS_N=$((PASS_N + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL_N=$((FAIL_N + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }

# Docker needs host-style paths for bind mounts on Windows (Git Bash). No-op elsewhere.
host_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

# make_work <prefix>: private temp dir, removed by the caller's trap.
make_work() { mktemp -d "${TMPDIR:-/tmp}/carelog-tls-$1.XXXXXX"; }

# summary: prints totals and returns non-zero when any check failed.
summary() {
  printf 'SUMMARY %s: %d passed, %d failed\n' "$1" "$PASS_N" "$FAIL_N"
  [ "$FAIL_N" -eq 0 ]
}
