#!/usr/bin/env bash
# Exercise the exact production package/extract/install route without release
# authorization or Git mutations. Inputs must be real native artifacts.
set -euo pipefail
cd "$(dirname "$0")/.."
. ./tests/portable.sh
compiler=${ZNC:-$(zag_native_compiler "$PWD")}
daemon=${ZAGD:-./zagd}
case "$(uname -s):$(uname -m)" in
    Darwin:arm64) platform=macos-arm64; daemon=${ZAGD:-./zagd-macos-arm64} ;;
    Linux:x86_64|Linux:amd64) platform=linux-x86_64 ;;
    Linux:aarch64|Linux:arm64) platform=linux-arm64; daemon=${ZAGD:-./zagd-linux-arm64} ;;
    *) echo 'release package roundtrip: unsupported native host' >&2; exit 2 ;;
esac
vsix=${ZAG_VSIX:-../editors/vscode/zag-lang.vsix}
if [ ! -x "$compiler" ] || [ ! -x "$daemon" ] || [ ! -f "$vsix" ]; then
    echo 'release package roundtrip: supply native ZNC, ZAGD, and a built ZAG_VSIX' >&2
    exit 2
fi
case "$compiler" in /*) ;; *) compiler="$PWD/$compiler" ;; esac
case "$daemon" in /*) ;; *) daemon="$PWD/$daemon" ;; esac
case "$vsix" in /*) ;; *) vsix="$PWD/$vsix" ;; esac
version=$(zag_compiler_version "$compiler")
work=$(mktemp -d "${TMPDIR:-/tmp}/zag-real-package.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir "$work/output" "$work/poison-bin"
cat >"$work/poison-bin/git" <<'SH'
#!/usr/bin/env bash
printf 'unexpected Git invocation: %s\n' "$*" >>"$ZAG_PACKAGE_GIT_SENTINEL"
exit 97
SH
chmod +x "$work/poison-bin/git"
export ZAG_PACKAGE_GIT_SENTINEL="$work/git-invoked"
PATH="$work/poison-bin:$PATH" bash tools/package-release.sh \
    "$version" "$platform" "$compiler" "$daemon" "$vsix" "$work/output"
test ! -e "$ZAG_PACKAGE_GIT_SENTINEL"
archive="$work/output/zag-$version-$platform.tar.gz"
test -s "$archive"
test -s "$archive.sha256"
archive_before=$(zag_sha256_file "$archive")
test "$(awk 'NR == 1 { print $1 }' "$archive.sha256")" = "$archive_before"
test "$(awk 'NR == 1 { print $2 }' "$archive.sha256")" = "$(basename "$archive")"

# Publication must never clobber an existing archive, even on a repeat run.
if PATH="$work/poison-bin:$PATH" bash tools/package-release.sh \
    "$version" "$platform" "$compiler" "$daemon" "$vsix" "$work/output" \
    >"$work/repeat.log" 2>&1; then
    echo 'release package roundtrip: overwrote an existing archive' >&2
    exit 1
fi
grep -q 'refusing to replace' "$work/repeat.log"
test "$(zag_sha256_file "$archive")" = "$archive_before"
test ! -e "$ZAG_PACKAGE_GIT_SENTINEL"

mkdir "$work/invalid-output"
if bash tools/package-release.sh '../invalid' "$platform" \
    "$compiler" "$daemon" "$vsix" "$work/invalid-output" \
    >"$work/invalid-version.log" 2>&1; then
    echo 'release package roundtrip: accepted an unsafe version' >&2
    exit 1
fi
test -z "$(find "$work/invalid-output" -mindepth 1 -print -quit)"
echo 'release package roundtrip: PASS actual archive/extraction/install, installed std, checksum, no Git, no clobber'
