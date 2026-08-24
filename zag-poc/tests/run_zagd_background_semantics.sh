#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

tmp=$(mktemp -d /tmp/zagd-background-sema.XXXXXX)
native_compiler=./znc
case "$(uname -s):$(uname -m)" in
    Darwin:arm64) native_compiler=./znc-macos-arm64 ;;
    Linux:aarch64|Linux:arm64) native_compiler=./znc-linux-arm64 ;;
esac
compiler=${ZNC:-$native_compiler}
daemon_source=selfhost/zagd_daemon.zag
if [ "$(uname -s):$(uname -m)" = Darwin:arm64 ]; then
    daemon_source=selfhost/zagd_macos_daemon.zag
fi
case "$compiler" in
    /*) ;;
    *) compiler="$PWD/${compiler#./}" ;;
esac
test -x "$compiler"
cleanup() {
    if [ -d "$tmp/project" ]; then
        (cd "$tmp/project" && "$compiler" shutdown >/dev/null 2>&1) || true
        printf stop > "$tmp/project/.zagd.stop" 2>/dev/null || true
        for _ in $(seq 1 100); do
            test ! -e "$tmp/project/.zagd.lock" && break
            sleep 0.01
        done
    fi
    # The daemon can complete its final atomic status publication just after
    # the lock disappears; retry only inside this unique mktemp directory.
    for _ in $(seq 1 20); do
        rm -rf "$tmp" || true
        test ! -e "$tmp" && return
        sleep 0.01
    done
    test ! -e "$tmp"
}
trap cleanup EXIT

"$compiler" "$daemon_source" -o "$tmp/zagd" --no-zagd --no-analyze >/dev/null
ln -s "$compiler" "$tmp/znc"
mkdir "$tmp/project"
printf '[package]\nname = "background-sema"\nversion = "0.0.1"\n' > "$tmp/project/zag.mod"
printf 'pub fn initial() i32 { return 1; }\nfn main() i32 { return initial(); }\n' > "$tmp/project/app.zag"

# No foreground check seeds this project. The daemon owns the first manifest.
(cd "$tmp/project" && "$tmp/znc" watch app.zag --mode light >/dev/null)
for _ in $(seq 1 1000); do
    grep -q '^state=idle$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
if [ "$(uname -s):$(uname -m)" = Darwin:arm64 ]; then
    # The Darwin daemon is a supported advisory kqueue watcher, but semantic
    # planner manifests remain Linux-only. Verify its explicit boundary and
    # clean shutdown rather than treating a Linux planner record as portable.
    grep -q '^target=macos-arm64$' "$tmp/project/.zagd.status"
    grep -q '^semantic_manifest=false$' "$tmp/project/.zagd.status"
    test ! -e "$tmp/project/.zag-cache/zagd/semantic.record"
    printf stop > "$tmp/project/.zagd.stop"
    for _ in $(seq 1 1000); do
        grep -q '^state=stopped$' "$tmp/project/.zagd.status" 2>/dev/null && break
        sleep 0.01
    done
    grep -q '^state=stopped$' "$tmp/project/.zagd.status"
    echo 'zagd background semantics: macOS advisory watcher pass'
    exit 0
fi
test -e "$tmp/project/.zag-cache/zagd/semantic.record"

# Simulate an agent's partial write immediately followed by its final save.
printf 'pub fn broken( i32 {\n' > "$tmp/project/app.zag"
printf 'pub fn final_value() i32 { return 29; }\nfn main() i32 { return final_value(); }\n' > "$tmp/project/app.zag"
for _ in $(seq 1 1000); do
    grep -q '^public_fn=fn final_value->i32!' "$tmp/project/.zag-cache/zagd/semantic.record" 2>/dev/null && break
    sleep 0.01
done
grep -q '^complete=true$' "$tmp/project/.zag-cache/zagd/semantic.record"
grep -q '^public_fn=fn final_value->i32!' "$tmp/project/.zag-cache/zagd/semantic.record"
final_bytes=$(wc -c < "$tmp/project/app.zag" | tr -d ' ')
grep -Eq "^source=[0-9]+,[0-9]+,${final_bytes}$" "$tmp/project/.zag-cache/zagd/semantic.record"
grep -q '^semantic_manifest=true$' "$tmp/project/.zagd.status"

# The explicitly selected root is daemon authority. A mutable compatibility
# control file written by an invalid external source path must not redirect it.
test ! -e "$tmp/project/.zagd.root-source"
printf 'missing.zag\n' > "$tmp/project/.zagd.root-source"
printf 'pub fn authority_value() i32 { return 31; }\nfn main() i32 { return authority_value(); }\n' > "$tmp/project/app.zag"
for _ in $(seq 1 1000); do
    grep -q '^public_fn=fn authority_value->i32!' "$tmp/project/.zag-cache/zagd/semantic.record" 2>/dev/null && break
    sleep 0.01
done
grep -q '^complete=true$' "$tmp/project/.zag-cache/zagd/semantic.record"
grep -q '^public_fn=fn authority_value->i32!' "$tmp/project/.zag-cache/zagd/semantic.record"

# A stable invalid source must remove, not retain, the prior valid manifest.
printf 'pub fn incomplete( i32 {\n' > "$tmp/project/app.zag"
for _ in $(seq 1 1000); do
    test ! -e "$tmp/project/.zag-cache/zagd/semantic.record" &&
        grep -q '^semantic_manifest=false$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
test ! -e "$tmp/project/.zag-cache/zagd/semantic.record"
grep -q '^semantic_manifest=false$' "$tmp/project/.zagd.status"

printf stop > "$tmp/project/.zagd.stop"
for _ in $(seq 1 1000); do
    grep -q '^state=stopped$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
grep -q '^state=stopped$' "$tmp/project/.zagd.status"
echo 'zagd background semantics: pass'
