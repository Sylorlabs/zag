#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
ZNC=${ZNC:-./znc}
tmp=$(mktemp -d /tmp/zag-x86-sse2-memcpy.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

"$ZNC" tests/x86_sse2_memcpy.zag --cpu generic -o "$tmp/generic" --no-analyze >/dev/null
"$tmp/generic"
"$ZNC" tests/x86_sse2_memcpy.zag --cpu native -o "$tmp/native" --no-analyze >/dev/null
"$tmp/native"

# F3 0F 6F /r and F3 0F 7F /r are MOVDQU load/store.  They are SSE2 baseline
# instructions, not AVX/VEX encodings; this proves the generated runtime path
# is present in both permitted x86-64 profiles.
bytes=$(od -An -tx1 -v "$tmp/generic" | tr '\n' ' ')
grep -q 'f3 0f 6f' <<<"$bytes"
grep -q 'f3 0f 7f' <<<"$bytes"
cmp -s "$tmp/generic" "$tmp/native"
echo "x86 SSE2 memcpy: generic/native execution and MOVDQU emission pass"
