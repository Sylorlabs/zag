#!/usr/bin/env bash
# End-to-end native Apple Silicon live text replacement.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/tests/portable.sh"

if [ "$(zag_native_platform)" != macos-arm64 ]; then
    echo 'macOS hot reload: unsupported host (requires Apple Silicon macOS)' >&2
    exit 2
fi

compiler=${ZNC:-$(zag_native_compiler "$root")}
case "$compiler" in
    /*) ;;
    *) compiler="$root/${compiler#./}" ;;
esac

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-macos-hot-reload.XXXXXX")
live_pid=
cleanup() {
    : >"$tmp/.zag_hotstop" 2>/dev/null || true
    if [ -n "$live_pid" ] && zag_process_running "$live_pid"; then
        zag_terminate_process_tree "$live_pid" ""
        wait "$live_pid" 2>/dev/null || true
    fi
    rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

pass=0
fail=0
record() {
    local label=$1
    shift
    if "$@"; then
        echo "  ok  $label"
        pass=$((pass + 1))
    else
        echo "  XX  $label"
        fail=$((fail + 1))
    fi
}

hot_text_protections() {
    otool -l "$1" | awk '
        $1 == "segname" { text = ($2 == "__TEXT") }
        text && $1 == "maxprot" { max = $2 }
        text && $1 == "initprot" { init = $2; exit }
        END { exit !(max == "0x00000007" && init == "0x00000005") }
    '
}

cd "$tmp"

# A regular signed image must retain immutable RX text. The live-patch mode is
# explicit and must not weaken every Mach-O the compiler emits.
if zag_run_bounded 180 "$compiler" "$root/tests/macos_text_protect_probe.zag" \
    --target macos-arm64 --no-zagd --no-analyze --no-foreground-cache \
    -o "$tmp/regular" >"$tmp/regular-build.out" 2>"$tmp/regular-build.err"; then
    set +e
    zag_run_bounded 15 "$tmp/regular"
    regular_status=$?
    set -e
    record 'regular signed image refuses writable text' \
        test "$regular_status" -eq 33
else
    echo '  XX  regular text-protection probe compiles'
    exit 1
fi

if zag_run_bounded 300 "$compiler" "$root/tests/macos_hot_live.zag" \
    --target macos-arm64 --hot --no-zagd --no-analyze --no-foreground-cache \
    -o "$tmp/live" >"$tmp/build.out" 2>"$tmp/build.err"; then
    record 'hot build is a signed native executable' \
        zag_assert_native_executable "$tmp/live"
    record 'hot build records native text layout' test -s "$tmp/.zag_hotlen"
    record 'hot build records native data layout' test -s "$tmp/.zag_hotdlen"
    record 'hot build records page/import layout contract' \
        sh -c 'grep -q "^macos-arm64-wx-v1;vm-page=16384;code-off=4096;fn-entry-align=16384;text-end-align=16384;edition2027=0;safety-checked=0;sanitize-memory=0;imports=" "$1"' \
            _ "$tmp/.zag_hotlayout"
    record 'hot build starts RX with an explicit write-capable maximum' \
        hot_text_protections "$tmp/live"
else
    echo '  XX  native --hot build'
    sed -n '1,160p' "$tmp/build.out" >&2
    sed -n '1,160p' "$tmp/build.err" >&2
    exit 1
fi

# A non-layout-preserving edit must fail before a patch file is published.
set +e
zag_run_bounded 300 "$compiler" hot-patch \
    "$root/tests/macos_hot_live_size_change.zag" --target macos-arm64 \
    --no-zagd --no-analyze --no-foreground-cache \
    >"$tmp/size-change.out" 2>"$tmp/size-change.err"
size_status=$?
set -e
record 'size-changing patch is rejected' test "$size_status" -ne 0
record 'size-changing patch publishes no bytes' test ! -s "$tmp/.zag_hotpatch"
record 'size-changing rejection names the layout guard' \
    sh -c 'grep -q "layout changed; rebuild required" "$1" "$2"' \
        _ "$tmp/size-change.out" "$tmp/size-change.err"

# A patch must be lowered under the exact edition/safety modes recorded by the
# running build. Matching aggregate lengths cannot authorize a mode change.
set +e
zag_run_bounded 300 "$compiler" hot-patch \
    "$root/tests/macos_hot_live_patch.zag" --target macos-arm64 \
    --safety=checked --no-zagd --no-analyze --no-foreground-cache \
    >"$tmp/mode-change.out" 2>"$tmp/mode-change.err"
mode_status=$?
set -e
record 'safety-mode-changing patch is rejected' test "$mode_status" -ne 0
record 'safety-mode rejection publishes no bytes' test ! -s "$tmp/.zag_hotpatch"
record 'safety-mode rejection names the mode layout guard' \
    sh -c 'grep -q "page/import/mode layout changed; rebuild required" "$1" "$2"' \
        _ "$tmp/mode-change.out" "$tmp/mode-change.err"

# Stage the valid edit outside the live process's directory first. Comparing
# raw __text there proves that one complete function page changes and every
# other page remains byte-stable before the patch becomes visible atomically.
mkdir "$tmp/stage"
cp "$tmp/.zag_hotlen" "$tmp/.zag_hotdlen" "$tmp/.zag_hotlayout" "$tmp/stage/"
stage_same_layout() {
    (
        cd "$tmp/stage"
        zag_run_bounded 300 "$compiler" hot-patch \
            "$root/tests/macos_hot_live_patch.zag" --target macos-arm64 \
            --no-zagd --no-analyze --no-foreground-cache
    )
}
record 'same-layout native patch stages' stage_same_layout

code_len=$(tr -d '[:space:]' <"$tmp/.zag_hotlen")
case "$code_len" in
    ''|*[!0-9]*) echo '  XX  invalid native text layout length' >&2; exit 1 ;;
esac
dd if="$tmp/live" of="$tmp/base.text" bs=1 skip=4096 count="$code_len" 2>/dev/null
base_len=$(wc -c <"$tmp/base.text" | tr -d '[:space:]')
patch_len=$(wc -c <"$tmp/stage/.zag_hotpatch" | tr -d '[:space:]')
record 'staged patch covers the complete recorded text' \
    test "$base_len" -eq "$code_len" -a "$patch_len" -eq "$code_len"

set +e
cmp -l "$tmp/base.text" "$tmp/stage/.zag_hotpatch" >"$tmp/page.diff"
cmp_status=$?
set -e
record 'replacement contains a real machine-code change' test "$cmp_status" -eq 1
read -r changed_pages changed_prefix <<EOF
$(awk '{ page=int(($1-1+4096)/16384); if (page==0) prefix=1; if (!(page in seen)) { seen[page]=1; count++ } } END { print count+0, prefix+0 }' "$tmp/page.diff")
EOF
mapped_pages=$(((4096 + code_len) / 16384))
record 'recorded text ends on a 16 KiB VM boundary' \
    test $(((4096 + code_len) % 16384)) -eq 0
record 'hot image spans multiple aligned VM pages' test "$mapped_pages" -ge 3
record 'replacement changes exactly one function page' test "$changed_pages" -eq 1
record 'Mach-O header page suffix remains immutable' test "$changed_prefix" -eq 0
record 'all non-target function pages remain byte-stable' \
    test "$changed_pages" -lt "$mapped_pages"

# Run the original image, publish the inspected patch, and require the existing
# PID to observe new text and return 42. This covers RX->RW->RX transitions,
# instruction-cache invalidation, patch consumption, and state continuity.
"$tmp/live" >"$tmp/live.out" 2>"$tmp/live.err" &
live_pid=$!
sleep 0.4
if ! zag_process_running "$live_pid"; then
    echo '  XX  original hot image stayed alive awaiting a patch'
    fail=$((fail + 1))
else
    record 'original hot image stays alive awaiting a patch' true
fi

record 'inspected patch publishes atomically' \
    mv "$tmp/stage/.zag_hotpatch" "$tmp/.zag_hotpatch"

attempt=0
while zag_process_running "$live_pid" && [ "$attempt" -lt 100 ]; do
    sleep 0.1
    attempt=$((attempt + 1))
done
if zag_process_running "$live_pid"; then
    live_status=124
    zag_terminate_process_tree "$live_pid" ""
    wait "$live_pid" 2>/dev/null || true
else
    set +e
    wait "$live_pid"
    live_status=$?
    set -e
fi
live_pid=

if [ "$live_status" -ne 42 ]; then
    echo "  ..  replacement process exit=$live_status" >&2
fi
record 'running PID executes replacement text' test "$live_status" -eq 42
record 'runtime consumes the staged patch' test ! -s "$tmp/.zag_hotpatch"
record 'live replacement emits no diagnostics' test ! -s "$tmp/live.err"

echo "macOS hot reload: pass=$pass fail=$fail"
test "$fail" -eq 0
