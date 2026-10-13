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
printf 'pub fn imported_value() i32 { return 7; }\n' > "$tmp/project/lib.zag"
printf '@import("lib.zag")\npub fn initial() i32 { return imported_value(); }\nfn main() i32 { return initial(); }\n' > "$tmp/project/app.zag"

# No foreground check seeds this project. The daemon owns the first manifest.
(cd "$tmp/project" && "$tmp/znc" watch app.zag --mode light >/dev/null)
for _ in $(seq 1 1000); do
    grep -q '^state=idle$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
test -e "$tmp/project/.zag-cache/zagd/semantic.record"

# Imported modules and dependency metadata are compiler inputs even when the
# selected root's bytes do not change. The Darwin adapter combines exact vnode
# watches with the same bounded input-fingerprint fallback, so this regression
# applies to both native daemons.
before_module=$(grep '^module_node=lib.zag' "$tmp/project/.zag-cache/zagd/semantic.record")
before_events=$(sed -n 's/^events=//p' "$tmp/project/.zagd.status")
printf '// imported dependency edit\npub fn imported_value() i32 { return 11; }\n' > "$tmp/project/lib.zag"
for _ in $(seq 1 1000); do
    current_module=$(grep '^module_node=lib.zag' "$tmp/project/.zag-cache/zagd/semantic.record" 2>/dev/null || true)
    current_events=$(sed -n 's/^events=//p' "$tmp/project/.zagd.status" 2>/dev/null || true)
    if [ -n "$current_module" ] && [ "$current_module" != "$before_module" ] &&
       [ "${current_events:-0}" -gt "${before_events:-0}" ]; then
        break
    fi
    sleep 0.01
done
test "$(grep '^module_node=lib.zag' "$tmp/project/.zag-cache/zagd/semantic.record")" != "$before_module"
test "$(sed -n 's/^events=//p' "$tmp/project/.zagd.status")" -gt "$before_events"
grep -q '^semantic_manifest=true$' "$tmp/project/.zagd.status"

if [ "$(uname -s):$(uname -m)" = Darwin:arm64 ]; then
    # Rearming must survive more than one atomic editor save of the same
    # imported vnode. A parent-directory event catches each rename, and the
    # replacement file receives a fresh exact watch before the next edit.
    for value in 13 17; do
        atomic_module=$(grep '^module_node=lib.zag' "$tmp/project/.zag-cache/zagd/semantic.record")
        atomic_events=$(sed -n 's/^events=//p' "$tmp/project/.zagd.status")
        printf '// successive atomic dependency edit\npub fn imported_value() i32 { return %s; }\n' "$value" \
            >"$tmp/project/.lib.next"
        mv "$tmp/project/.lib.next" "$tmp/project/lib.zag"
        for _ in $(seq 1 1000); do
            next_module=$(grep '^module_node=lib.zag' "$tmp/project/.zag-cache/zagd/semantic.record" 2>/dev/null || true)
            next_events=$(sed -n 's/^events=//p' "$tmp/project/.zagd.status" 2>/dev/null || true)
            if [ -n "$next_module" ] && [ "$next_module" != "$atomic_module" ] &&
               [ "${next_events:-0}" -gt "${atomic_events:-0}" ]; then
                break
            fi
            sleep 0.01
        done
        test "$(grep '^module_node=lib.zag' "$tmp/project/.zag-cache/zagd/semantic.record")" != "$atomic_module"
        test "$(sed -n 's/^events=//p' "$tmp/project/.zagd.status")" -gt "$atomic_events"
    done
fi

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

if [ "$(uname -s):$(uname -m)" = Darwin:arm64 ]; then
    # A missing selected root is an early check failure. It must still remove
    # the old manifest, then recover after an atomic rename restores the file.
    mv "$tmp/project/app.zag" "$tmp/project/app.zag.saved"
    for _ in $(seq 1 1000); do
        test ! -e "$tmp/project/.zag-cache/zagd/semantic.record" &&
            grep -q '^last_check_status=127$' "$tmp/project/.zagd.status" 2>/dev/null && break
        sleep 0.01
    done
    test ! -e "$tmp/project/.zag-cache/zagd/semantic.record"
    grep -q '^semantic_manifest=false$' "$tmp/project/.zagd.status"
    mv "$tmp/project/app.zag.saved" "$tmp/project/app.zag"
    for _ in $(seq 1 1000); do
        grep -q '^public_fn=fn authority_value->i32!' "$tmp/project/.zag-cache/zagd/semantic.record" 2>/dev/null && break
        sleep 0.01
    done
    grep -q '^semantic_manifest=true$' "$tmp/project/.zagd.status"
fi

# A stable invalid source must remove, not retain, the prior valid manifest.
printf 'pub fn incomplete( i32 {\n' > "$tmp/project/app.zag"
for _ in $(seq 1 1000); do
    test ! -e "$tmp/project/.zag-cache/zagd/semantic.record" &&
        grep -q '^semantic_manifest=false$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
test ! -e "$tmp/project/.zag-cache/zagd/semantic.record"
grep -q '^semantic_manifest=false$' "$tmp/project/.zagd.status"

if [ "$(uname -s):$(uname -m)" = Darwin:arm64 ]; then
    # Exceed the fixed vnode descriptor budget. The adapter must close every
    # partial kqueue watch, report its bounded polling fallback, and continue
    # noticing both root recovery and later imported-module-only edits.
    # Build the oversized topology before a fresh start: steady-state compiler
    # input tracking intentionally ignores empty-directory churn.
    printf stop > "$tmp/project/.zagd.stop"
    for _ in $(seq 1 1000); do
        test ! -e "$tmp/project/.zagd.lock" && break
        sleep 0.01
    done
    test ! -e "$tmp/project/.zagd.lock"
    for i in $(seq 1 520); do mkdir "$tmp/project/cap-$i"; done
    (cd "$tmp/project" && "$tmp/znc" watch app.zag --mode light >/dev/null)
    for _ in $(seq 1 1000); do
        grep -q '^watcher=polling-project-inputs$' "$tmp/project/.zagd.status" 2>/dev/null && break
        sleep 0.01
    done
    grep -q '^watcher=polling-project-inputs$' "$tmp/project/.zagd.status"
    grep -q '^input_scan_complete=true$' "$tmp/project/.zagd.status"

    printf '@import("lib.zag")\npub fn recovered() i32 { return imported_value(); }\nfn main() i32 { return recovered(); }\n' > "$tmp/project/app.zag"
    for _ in $(seq 1 1000); do
        grep -q '^public_fn=fn recovered->i32!' "$tmp/project/.zag-cache/zagd/semantic.record" 2>/dev/null && break
        sleep 0.01
    done
    grep -q '^semantic_manifest=true$' "$tmp/project/.zagd.status"
    cap_module=$(grep '^module_node=lib.zag' "$tmp/project/.zag-cache/zagd/semantic.record")
    cap_events=$(sed -n 's/^events=//p' "$tmp/project/.zagd.status")
    printf '// polling fallback dependency edit\npub fn imported_value() i32 { return 19; }\n' > "$tmp/project/lib.zag"
    for _ in $(seq 1 1000); do
        next_module=$(grep '^module_node=lib.zag' "$tmp/project/.zag-cache/zagd/semantic.record" 2>/dev/null || true)
        next_events=$(sed -n 's/^events=//p' "$tmp/project/.zagd.status" 2>/dev/null || true)
        if [ -n "$next_module" ] && [ "$next_module" != "$cap_module" ] &&
           [ "${next_events:-0}" -gt "${cap_events:-0}" ]; then
            break
        fi
        sleep 0.01
    done
    test "$(grep '^module_node=lib.zag' "$tmp/project/.zag-cache/zagd/semantic.record")" != "$cap_module"
    test "$(sed -n 's/^events=//p' "$tmp/project/.zagd.status")" -gt "$cap_events"
fi

printf stop > "$tmp/project/.zagd.stop"
for _ in $(seq 1 1000); do
    grep -q '^state=stopped$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
grep -q '^state=stopped$' "$tmp/project/.zagd.status"

if [ "$(uname -s):$(uname -m)" = Darwin:arm64 ]; then
    env ZNC="$compiler" bash tests/run_zagd_macos_resource_stress.sh
fi
echo 'zagd background semantics: pass'
