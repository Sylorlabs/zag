#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
. tests/portable.sh

if [ "$(uname -s):$(uname -m)" != Darwin:arm64 ]; then
    echo 'macOS concurrency services require Apple Silicon macOS' >&2
    exit 2
fi
compiler=${ZNC:-"$root/znc-macos-arm64"}
case "$compiler" in /*) ;; *) compiler="$root/${compiler#./}" ;; esac
test -x "$compiler"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-macos-concurrency.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

project="$tmp/project"
mkdir -p "$project"
printf '%s\n' \
    'name = "macos-concurrency-services"' \
    'version = "0"' \
    'edition = "2027"' >"$project/zag.mod"

build() {
    local source=$1
    local output=$2
    cp "$source" "$project/main.zag"
    (cd "$project" && zag_run_bounded 180 "$compiler" main.zag \
        --target macos-arm64 --dynamic --safety=checked --analyze-strict \
        --no-zagd --no-foreground-cache -o "$output") >/dev/null
}

build tests/macos_kqueue_user_probe.zag "$tmp/kernel-probe"
set +e
zag_run_bounded 10 "$tmp/kernel-probe"
probe_rc=$?
set -e
if [ "$probe_rc" -ne 42 ]; then
    echo "macOS EVFILT_USER kqueue kernel probe returned $probe_rc" >&2
    exit 1
fi

build tests/reference_apps/async_worker/macos_main.zag "$tmp/worker"
build tests/reference_apps/async_worker/macos_main.zag "$tmp/worker-repeat"
cmp "$tmp/worker" "$tmp/worker-repeat"
zag_assert_native_executable "$tmp/worker"
codesign --verify --strict "$tmp/worker"

dyld_info -opcodes "$tmp/worker" >"$tmp/binds"
for symbol in pthread_create pthread_join; do
    grep -q "SET_SYMBOL_TRAILING_FLAGS_IMM.*_${symbol}" "$tmp/binds"
done

zag_run_bounded 15 "$tmp/worker" >"$tmp/out" 2>"$tmp/err"
printf 'macos-async-worker jobs=8 result_sum=212 timeout=1\n' | cmp -s - "$tmp/out"
test ! -s "$tmp/err"

echo 'macOS concurrency services: PASS EVFILT_USER kqueue SPSC + bounded timeout + native worker'
