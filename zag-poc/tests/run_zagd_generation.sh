#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C; cd "$(dirname "$0")/.."; ZNC_BIN=${ZNC:-./znc}; case "$ZNC_BIN" in /*) ;; *) ZNC_BIN="$PWD/${ZNC_BIN#./}" ;; esac
ZNC="$ZNC_BIN" bash tests/run_zagd_generation_candidate.sh
if [[ $(uname -s):$(uname -m) == Linux:x86_64 ]]; then tmp=$(mktemp -d "${TMPDIR:-/tmp}/zagd-generation.XXXXXX"); trap 'rm -rf "$tmp"' EXIT HUP INT TERM; mkdir -p "$tmp/state"; "$ZNC_BIN" selfhost/zagd_generation_test.zag -o "$tmp/test" --no-zagd --no-analyze --no-foreground-cache >/dev/null; "$tmp/test" "$tmp/state"; if find "$tmp/state/.zag-cache/zagd" -mindepth 1 -type d -print -quit | grep -q .; then echo 'zagd generation registry violated the flat cache contract' >&2; exit 1; fi; grep -q '^generation_execution=bounded-finite-sandbox$' "$tmp/state/.zag-cache/zagd/generation-pointers.record"; fi
echo 'zagd generation registry: PASS (bounded sandbox + canary promotion/rollback)'
