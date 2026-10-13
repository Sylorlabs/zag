#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
. tests/portable.sh
if [ "$(uname -s):$(uname -m)" != Darwin:arm64 ]; then
    echo 'macOS filesystem ABI requires native Apple Silicon' >&2
    exit 2
fi
compiler=${ZNC:-$root/znc-macos-arm64}
case "$compiler" in /*) ;; *) compiler="$root/${compiler#./}" ;; esac
work=$(mktemp -d "${TMPDIR:-/tmp}/zag-macos-fs-abi.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
work=$(cd -P "$work" && pwd -P)
mkdir "$work/project" "$work/bin"
ln -s payload "$work/project/payload-link"

for fixture in macos_foreground_cache_fs_probe macos_cache_raw_abi_negative macos_executable_identity; do
    "$compiler" "tests/$fixture.zag" --target macos-arm64 --no-zagd \
        --no-analyze --no-foreground-cache -o "$work/$fixture"
    zag_assert_native_executable "$work/$fixture"
done
expect_42() {
    local status=0
    "$@" || status=$?
    [ "$status" -eq 42 ]
}
expect_42 "$work/macos_foreground_cache_fs_probe" "$work/project"
expect_42 "$work/macos_cache_raw_abi_negative"
identity="$work/macos_executable_identity"
"$identity" "$identity"
ln -s "$identity" "$work/bin/identity-alias"
"$work/bin/identity-alias" "$identity"
(cd / && PATH="$work/bin:/usr/bin:/bin" identity-alias "$identity")
echo 'macOS filesystem and executable identity ABI: PASS'
