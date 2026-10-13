#!/usr/bin/env bash
# Exercise the release archive layout contract without running release.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
. ./tests/portable.sh

# Exercise banner parsing without needing a compiler for this layout-only
# suite. Real compiler banners are checked again by the archive roundtrip.
(
    zag_run_bounded() { printf '%s\n' "$test_banner"; }
    test_banner='znc 2026.07.0-dev (edition 2026)'
    test "$(zag_compiler_version ignored)" = 2026.07.0-dev
    test_banner='znc 2026.07.0 (edition 2027)'
    test "$(zag_compiler_version ignored)" = 2026.07.0
    for test_banner in '2026.07.0' 'znc ../../bad (edition 2026)' \
        'znc 2026.07.0 (edition unknown)' $'znc 2026.07.0 (edition 2026)\nextra'; do
        if zag_compiler_version ignored >/dev/null 2>&1; then
            echo 'release layout self-test: invalid version banner accepted' >&2
            exit 1
        fi
    done
)

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-release-layout.XXXXXX")
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT HUP INT TERM

fixture="$tmp/zag-2099.01.0-linux-x86_64"
mkdir -p \
    "$fixture/examples" \
    "$fixture/programs" \
    "$fixture/selfhost/native" \
    "$fixture/selfhost/lsp" \
    "$fixture/std" \
    "$fixture/tests" \
    "$fixture/tools" \
    "$fixture/docs" \
    "$fixture/editors/vscode"

required_files=(
    Makefile
    LICENSE
    README.md
    BOOTSTRAP.md
    INSTALL.md
    CHANGELOG.md
    COMPATIBILITY.md
    NATIVE_BOOTSTRAP_REPRODUCIBILITY.md
    RELEASES.md
    VERSIONING.md
    znc.sha256
    examples/numeric.zag
    examples/zagd.conf
    programs/GAPS.md
    programs/arena.zag
    programs/csv_parser.zag
    programs/hash_map.zag
    programs/json_parser.zag
    programs/sort_bench.zag
    programs/state_machine.zag
    selfhost/native/znc.zag
    selfhost/zagd_daemon.zag
    selfhost/zagd_macos_daemon.zag
    selfhost/lsp/zag-lsp.zag
    std/checksum.zag
    tests/portable.sh
    tests/run_zagscript_install_layout.sh
    tools/package-release.sh
    docs/SUPPORT.md
    docs/MACOS_NATIVE_PARITY.md
    editors/vscode/LICENSE
    editors/vscode/package.json
    editors/vscode/package-lock.json
    zag-lang.vsix
)
for required_file in "${required_files[@]}"; do
    : >"$fixture/$required_file"
done
cp tests/check_release_package.sh "$fixture/tests/check_release_package.sh"
printf 'name = "zag"\nversion = "2099.01.0"\nedition = "2026"\n' \
    >"$fixture/zag.mod"

for required_executable in \
    znc zagd zag-lsp bootstrap.sh \
    tools/bootstrap-macos-seed.sh \
    tools/zagd-user-service.sh tools/zagd-launchd-service.sh; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$fixture/$required_executable"
    chmod +x "$fixture/$required_executable"
done

bash tests/check_release_package.sh --layout-only \
    "$fixture" linux-x86_64 2099.01.0

if [ "$(uname -s)" = Darwin ]; then
    /usr/bin/xattr -w com.zag.release-layout sentinel "$fixture/Makefile"
fi

COPYFILE_DISABLE=1 tar --no-xattrs -czf "$tmp/package.tar.gz" \
    -C "$tmp" "$(basename "$fixture")"
if [ "$(uname -s)" = Darwin ]; then
    /usr/bin/xattr -d com.zag.release-layout "$fixture/Makefile"
fi
mkdir "$tmp/extracted"
tar -xzf "$tmp/package.tar.gz" -C "$tmp/extracted"
if [ "$(uname -s)" = Darwin ] &&
   /usr/bin/xattr "$tmp/extracted/$(basename "$fixture")/Makefile" |
       grep -Fxq com.zag.release-layout; then
    echo "release layout self-test: archive retained extended attributes" >&2
    exit 1
fi
bash tests/check_release_package.sh --layout-only \
    "$tmp/extracted/$(basename "$fixture")" linux-x86_64 2099.01.0

mv "$fixture/LICENSE" "$fixture/LICENSE.saved"
if bash tests/check_release_package.sh --layout-only \
    "$fixture" linux-x86_64 2099.01.0 >/dev/null 2>&1; then
    echo "release layout self-test: missing LICENSE was accepted" >&2
    exit 1
fi
mv "$fixture/LICENSE.saved" "$fixture/LICENSE"

mv "$fixture/znc.sha256" "$fixture/znc.sha256.saved"
if bash tests/check_release_package.sh --layout-only \
    "$fixture" linux-x86_64 2099.01.0 >/dev/null 2>&1; then
    echo "release layout self-test: missing compiler checksum was accepted" >&2
    exit 1
fi
mv "$fixture/znc.sha256.saved" "$fixture/znc.sha256"

mv "$fixture/editors/vscode/package-lock.json" \
    "$fixture/editors/vscode/package-lock.json.saved"
if bash tests/check_release_package.sh --layout-only \
    "$fixture" linux-x86_64 2099.01.0 >/dev/null 2>&1; then
    echo "release layout self-test: missing editor lockfile was accepted" >&2
    exit 1
fi
mv "$fixture/editors/vscode/package-lock.json.saved" \
    "$fixture/editors/vscode/package-lock.json"

mv "$fixture/tools/zagd-launchd-service.sh" \
    "$fixture/tools/zagd-launchd-service.sh.saved"
if bash tests/check_release_package.sh --layout-only \
    "$fixture" linux-x86_64 2099.01.0 >/dev/null 2>&1; then
    echo "release layout self-test: missing install helper was accepted" >&2
    exit 1
fi
mv "$fixture/tools/zagd-launchd-service.sh.saved" \
    "$fixture/tools/zagd-launchd-service.sh"

mv "$fixture/tools/bootstrap-macos-seed.sh" \
    "$fixture/tools/bootstrap-macos-seed.sh.saved"
if bash tests/check_release_package.sh --layout-only \
    "$fixture" linux-x86_64 2099.01.0 >/dev/null 2>&1; then
    echo "release layout self-test: missing macOS seed helper was accepted" >&2
    exit 1
fi
mv "$fixture/tools/bootstrap-macos-seed.sh.saved" \
    "$fixture/tools/bootstrap-macos-seed.sh"

cp "$fixture/zag.mod" "$fixture/zag.mod.saved"
printf 'name = "zag"\nversion = "2099.02.0"\nedition = "2026"\n' \
    >"$fixture/zag.mod"
if bash tests/check_release_package.sh --layout-only \
    "$fixture" linux-x86_64 2099.01.0 >/dev/null 2>&1; then
    echo "release layout self-test: mismatched zag.mod version was accepted" >&2
    exit 1
fi
mv "$fixture/zag.mod.saved" "$fixture/zag.mod"

: >"$fixture/forbidden.o"
if bash tests/check_release_package.sh --layout-only \
    "$fixture" linux-x86_64 2099.01.0 >/dev/null 2>&1; then
    echo "release layout self-test: forbidden object was accepted" >&2
    exit 1
fi
rm "$fixture/forbidden.o"

: >"$fixture/selfhost/zagc"
chmod +x "$fixture/selfhost/zagc"
if bash tests/check_release_package.sh --layout-only \
    "$fixture" linux-x86_64 2099.01.0 >/dev/null 2>&1; then
    echo "release layout self-test: retired selfhost/zagc binary was accepted" >&2
    exit 1
fi
rm "$fixture/selfhost/zagc"

cp /bin/ls "$fixture/examples/stale-native"
if bash tests/check_release_package.sh --layout-only \
    "$fixture" linux-x86_64 2099.01.0 >/dev/null 2>&1; then
    echo "release layout self-test: extensionless stale native binary was accepted" >&2
    exit 1
fi
rm "$fixture/examples/stale-native"

mkdir "$fixture/editors/vscode/node_modules"
if bash tests/check_release_package.sh --layout-only \
    "$fixture" linux-x86_64 2099.01.0 >/dev/null 2>&1; then
    echo "release layout self-test: editor node_modules was accepted" >&2
    exit 1
fi
rmdir "$fixture/editors/vscode/node_modules"

mkdir "$fixture/editors/vscode/out"
if bash tests/check_release_package.sh --layout-only \
    "$fixture" linux-x86_64 2099.01.0 >/dev/null 2>&1; then
    echo "release layout self-test: stale editor build output was accepted" >&2
    exit 1
fi
rmdir "$fixture/editors/vscode/out"

: >"$fixture/.DS_Store"
if bash tests/check_release_package.sh --layout-only \
    "$fixture" linux-x86_64 2099.01.0 >/dev/null 2>&1; then
    echo "release layout self-test: macOS metadata was accepted" >&2
    exit 1
fi
rm "$fixture/.DS_Store"

: >"$fixture/._Makefile"
if bash tests/check_release_package.sh --layout-only \
    "$fixture" linux-x86_64 2099.01.0 >/dev/null 2>&1; then
    echo "release layout self-test: AppleDouble metadata was accepted" >&2
    exit 1
fi
rm "$fixture/._Makefile"

echo "release package layout self-test passed"
