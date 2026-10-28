#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

tmp=$(mktemp -d /tmp/zagd-buffer-lifetime.XXXXXX)
daemon_pid=
cleanup() {
    if [ -n "$daemon_pid" ]; then
        # A failed stale-record assertion must not leave a stopped daemon
        # blocking cleanup's wait.
        kill -CONT "$daemon_pid" 2>/dev/null || true
        printf stop > "$tmp/project/.zagd.stop" 2>/dev/null || true
        wait "$daemon_pid" 2>/dev/null || true
    fi
    rm -rf "$tmp"
}
trap cleanup EXIT

compiler=${ZNC_LIFETIME_TEST:-"$(pwd)/znc"}
daemon=${ZAGD_LIFETIME_TEST:-"$(pwd)/zagd"}
mkdir "$tmp/project"
printf '[package]\nname = "buffer-lifetime"\nversion = "0.0.1"\n' > "$tmp/project/zag.mod"
cat > "$tmp/project/app.zag" <<'ZAG'
fn main() i32 {
    let first: []f32 = zalloc(4);
    zfree(first);
    let second: []f32 = zalloc(8);
    zfree(second);
    return 0;
}
ZAG

(cd "$tmp/project" && "$compiler" check app.zag --no-zagd --no-analyze >/dev/null)
record="$tmp/project/.zag-cache/zagd/semantic.record"
grep -q $'^buffer_pair=main\tfirst=first\tfirst_bytes=32\tfirst_alloc_stmt=0\tfirst_free_stmt=1\tsecond=second\tsecond_bytes=64\tsecond_alloc_stmt=2\tsecond_free_stmt=3\treuse_bytes=32\tword_bytes=8\tnon_overlap=1\tbasis=proven-foreground-ast\tautomatic=0\tsource_changes=0\texecutable_authority=0\t' "$record"
before_source=$(sed -n 's/^source=//p' "$record")
before_graph=$(sed -n 's/^graph=//p' "$record")
before_fact=$(grep '^buffer_pair=' "$record")

"$daemon" --root "$tmp/project" --root-source app.zag --mode adaptive --window-ms 20 &
daemon_pid=$!
for _ in $(seq 1 1000); do
    if grep -q '^state=idle$' "$tmp/project/.zagd.status" 2>/dev/null &&
       test -f "$tmp/project/.zag-cache/zagd/candidates.record"; then
        break
    fi
    sleep 0.02
done
if [ ! -f "$tmp/project/.zag-cache/zagd/candidates.record" ]; then
    echo 'zagd did not publish lifetime candidates within the 20-second startup budget' >&2
    if [ -f "$tmp/project/.zagd.status" ]; then cat "$tmp/project/.zagd.status" >&2; fi
    if [ -f "$tmp/project/.zag-cache/zagd/semantic.record" ]; then
        head -12 "$tmp/project/.zag-cache/zagd/semantic.record" >&2
    fi
    exit 1
fi
grep -q '^lifetime_advice_supported=true$' "$tmp/project/.zag-cache/zagd/candidates.record"
grep -q '^lifetime_advice_automatic=false$' "$tmp/project/.zag-cache/zagd/candidates.record"
grep -q '^lifetime_advice_source_changes=false$' "$tmp/project/.zag-cache/zagd/candidates.record"
grep -q '^lifetime_provenance=proven-foreground-ast$' "$tmp/project/.zag-cache/zagd/candidates.record"
grep -q '^lifetime_pairs=1$' "$tmp/project/.zag-cache/zagd/candidates.record"
grep -q '^lifetime_reusable_bytes=32$' "$tmp/project/.zag-cache/zagd/candidates.record"
grep -q $'^candidate=11\tautomatic=0\tsupported=0\tequivalent=0\t' "$tmp/project/.zag-cache/zagd/candidates.record"
grep -q 'no buffer-reuse transform and end-to-end equivalence proof are implemented' "$tmp/project/.zag-cache/zagd/candidates.record"

(cd "$tmp/project" && "$compiler" suggest --format json > "$tmp/suggest.json")
grep -q '"id":"proven-buffer-lifetimes","supported":true,"automatic":false,"confidence":100,"evidence_basis":"proven-foreground-ast"' "$tmp/suggest.json" || {
    cat "$tmp/suggest.json" >&2
    cat "$tmp/project/.zagd.status" >&2
    echo 'zagd suggestion did not validate live singleton and semantic evidence' >&2
    exit 1
}
grep -q 'largest exact shared capacity 32 byte(s)' "$tmp/suggest.json"
grep -q '"source_changes":false' "$tmp/suggest.json"

# A filesystem event is only a hint. Until the foreground compiler publishes a
# checksum-bound record for the new bytes, the old record must be rejected.
kill -STOP "$daemon_pid"
daemon_state=
for _ in $(seq 1 100); do
    daemon_state=$(ps -o state= -p "$daemon_pid" 2>/dev/null | tr -d '[:space:]')
    case "$daemon_state" in T*) break ;; esac
    sleep 0.01
done
case "$daemon_state" in
    T*) ;;
    *) echo 'zagd did not stop before the stale-record check' >&2; exit 1 ;;
esac
printf '\n// comment-only stable edit\n' >> "$tmp/project/app.zag"
(cd "$tmp/project" && "$compiler" suggest --format json > "$tmp/stale.json")
grep -q '"available":false,"reason":"stale-module-graph"' "$tmp/stale.json"
kill -CONT "$daemon_pid"

printf stop > "$tmp/project/.zagd.stop"
wait "$daemon_pid"
daemon_pid=
rm -f "$tmp/project/.zagd.stop"
(cd "$tmp/project" && "$compiler" check app.zag --no-zagd --no-analyze >/dev/null)
after_source=$(sed -n 's/^source=//p' "$record")
after_graph=$(sed -n 's/^graph=//p' "$record")
after_fact=$(grep '^buffer_pair=' "$record")
test "$before_source" != "$after_source"
test "$before_graph" = "$after_graph"
test "$before_fact" = "$after_fact"

rm -f "$tmp/project/.zag-cache/zagd/candidates.record"
"$daemon" --root "$tmp/project" --root-source app.zag --mode adaptive --window-ms 20 &
daemon_pid=$!
for _ in $(seq 1 1000); do
    if grep -q '^state=idle$' "$tmp/project/.zagd.status" 2>/dev/null &&
       grep -q '^lifetime_pairs=1$' "$tmp/project/.zag-cache/zagd/candidates.record" 2>/dev/null; then
        break
    fi
    sleep 0.02
done
if ! grep -q '^lifetime_pairs=1$' "$tmp/project/.zag-cache/zagd/candidates.record" 2>/dev/null; then
    echo 'zagd did not refresh lifetime advice after the source-only change' >&2
    cat "$tmp/project/.zagd.status" >&2
    exit 1
fi
(cd "$tmp/project" && "$compiler" suggest --format json > "$tmp/comment.json")
grep -q '"id":"proven-buffer-lifetimes","supported":true,"automatic":false' "$tmp/comment.json"
grep -q 'largest exact shared capacity 32 byte(s)' "$tmp/comment.json"

printf stop > "$tmp/project/.zagd.stop"
wait "$daemon_pid"
daemon_pid=
echo "zagd exact buffer lifetime advisory: pass"
