#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
znc_bin=$(realpath "${ZNC:-./znc}")
tmp=$(mktemp -d /tmp/zag-script-capabilities.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

printf 'script;\nlet data=read_file("input.txt");\nprintln(data);\n' >"$tmp/read.zag"
printf 'allow_filesystem_read=false\nallow_filesystem_write=true\nallow_process=true\nmode=off\n' >"$tmp/.zagd.conf"
if "$znc_bin" "$tmp/read.zag" -o "$tmp/read" --no-zagd --no-analyze >"$tmp/out" 2>&1; then echo "denied filesystem capability unexpectedly compiled" >&2; exit 1; fi
grep -q 'read_file denied by allow_filesystem_read=false' "$tmp/out"
"$znc_bin" explain "$tmp/read.zag" --format json --no-zagd >"$tmp/explain.json"
grep -q '"capability_policy":{"filesystem_read":false,"filesystem_write":true,"process":true,"network":false,"basis":"proven"}' "$tmp/explain.json"

printf 'script;\nfn read_file(path:[]u8)[]u8{return "local";}\nprintln(read_file("ignored"));\n' >"$tmp/override.zag"
"$znc_bin" "$tmp/override.zag" -o "$tmp/override" --no-zagd --no-analyze >/dev/null
test "$("$tmp/override")" = local

printf 'script;\nlet result=process_run_timeout("true",100,16);\nreturn 0;\n' >"$tmp/process.zag"
printf 'allow_filesystem_read=true\nallow_filesystem_write=true\nallow_process=false\nmode=off\n' >"$tmp/.zagd.conf"
if "$znc_bin" "$tmp/process.zag" -o "$tmp/process" --no-zagd --no-analyze >"$tmp/out" 2>&1; then echo "denied process capability unexpectedly compiled" >&2; exit 1; fi
grep -q 'process_run_timeout denied by allow_process=false' "$tmp/out"

printf 'allow_process=maybe\nmode=off\n' >"$tmp/.zagd.conf"
"$znc_bin" "$tmp/read.zag" -o "$tmp/defaulted" --no-zagd --no-analyze >"$tmp/out" 2>&1
grep -q 'allow_process must be true or false; using documented defaults' "$tmp/out"

printf 'allow_filesystem_read=true\nallow_filesystem_write=true\nallow_process=true\nmode=off\n' >"$tmp/.zagd.conf"
printf ok >"$tmp/input.txt"
(cd "$tmp" && "$znc_bin" read.zag -o read --no-zagd --no-analyze >/dev/null && ./read) | grep -q '^ok$'
echo "script capabilities: PASS"
