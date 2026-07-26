#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
znc_bin=${ZNC:-./znc}
case "$znc_bin" in /*) ;; *) znc_bin="$(pwd)/${znc_bin#./}" ;; esac
tmp_dir=$(mktemp -d /tmp/zag-optimize-preview.XXXXXX)
trap 'rm -rf "$tmp_dir"' EXIT

printf '%s\n' 'fn main() i32 { return 7; }' >"$tmp_dir/source.zag"
before=$(sha256sum "$tmp_dir/source.zag" | awk '{print $1}')

# A missing daemon/snapshot is still a successful read-only inspection. It
# must not create an executable, modify source, or claim an optimization.
(cd "$tmp_dir" && "$znc_bin" optimize --preview --format text --no-zagd) >"$tmp_dir/preview.txt"
grep -q '^znc optimize preview: read-only advisory; source_changes=false$' "$tmp_dir/preview.txt"
grep -q '^zagd suggest: no active snapshot; regular Zag remains unchanged$' "$tmp_dir/preview.txt"

(cd "$tmp_dir" && "$znc_bin" optimize --preview --format json --no-zagd) >"$tmp_dir/preview.json"
grep -q '^\{"advisory":true,"available":false,"source_changes":false\}$' "$tmp_dir/preview.json"
after=$(sha256sum "$tmp_dir/source.zag" | awk '{print $1}')
test "$before" = "$after"
test ! -e "$tmp_dir/a.out"

if (cd "$tmp_dir" && "$znc_bin" optimize --preview --apply --no-zagd) >"$tmp_dir/apply.out" 2>"$tmp_dir/apply.err"; then
    echo "optimize preview unexpectedly accepted --apply" >&2
    exit 1
fi
grep -q 'mutation flags are unsupported' "$tmp_dir/apply.err"
if (cd "$tmp_dir" && "$znc_bin" optimize --preview --output candidate.zag --no-zagd) >"$tmp_dir/output.out" 2>"$tmp_dir/output.err"; then
    echo "optimize preview unexpectedly accepted --output" >&2
    exit 1
fi
grep -q 'mutation flags are unsupported' "$tmp_dir/output.err"
if (cd "$tmp_dir" && "$znc_bin" optimize --no-zagd) >"$tmp_dir/missing.out" 2>"$tmp_dir/missing.err"; then
    echo "optimize unexpectedly accepted a non-preview invocation" >&2
    exit 1
fi
grep -q 'only --preview is implemented' "$tmp_dir/missing.err"
if (cd "$tmp_dir" && "$znc_bin" optimize --preview --format yaml --no-zagd) >"$tmp_dir/format.out" 2>"$tmp_dir/format.err"; then
    echo "optimize preview unexpectedly accepted a non-JSON/text format" >&2
    exit 1
fi
grep -q -- '--format must be text or json' "$tmp_dir/format.err"

echo "optimize preview: PASS"
