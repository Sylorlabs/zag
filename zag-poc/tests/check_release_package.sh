#!/usr/bin/env bash
# Validate the install/bootstrap contract of a staged or extracted release tree.
set -euo pipefail

layout_only=0
if [ "${1:-}" = "--layout-only" ]; then
    layout_only=1
    shift
fi

if [ "$#" -ne 3 ]; then
    echo "usage: $0 [--layout-only] PACKAGE_ROOT PLATFORM VERSION" >&2
    exit 2
fi

package_root=$1
release_platform=$2
release_version=$3

case "$release_platform" in
    linux-x86_64|linux-arm64|macos-arm64) ;;
    *)
        echo "release package: unsupported platform: $release_platform" >&2
        exit 2
        ;;
esac

if [ ! -d "$package_root" ]; then
    echo "release package: package root is not a directory: $package_root" >&2
    exit 1
fi
package_root=$(cd "$package_root" && pwd -P)

release_package_fail=0

release_require_file() {
    if [ ! -f "$package_root/$1" ]; then
        echo "release package: missing required file: $1" >&2
        release_package_fail=1
    fi
}

release_require_dir() {
    if [ ! -d "$package_root/$1" ]; then
        echo "release package: missing required directory: $1" >&2
        release_package_fail=1
    fi
}

release_require_executable() {
    release_require_file "$1"
    if [ -f "$package_root/$1" ] && [ ! -x "$package_root/$1" ]; then
        echo "release package: required file is not executable: $1" >&2
        release_package_fail=1
    fi
}

release_required_files=(
    Makefile
    zag.mod
    LICENSE
    README.md
    BOOTSTRAP.md
    INSTALL.md
    CHANGELOG.md
    COMPATIBILITY.md
    NATIVE_BOOTSTRAP_REPRODUCIBILITY.md
    RELEASES.md
    VERSIONING.md
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
    tests/check_release_package.sh
    docs/SUPPORT.md
    docs/MACOS_NATIVE_PARITY.md
    editors/vscode/package.json
    zag-lang.vsix
)
for release_required_file in "${release_required_files[@]}"; do
    release_require_file "$release_required_file"
done

release_required_dirs=(examples programs selfhost std tests tools docs editors)
for release_required_dir in "${release_required_dirs[@]}"; do
    release_require_dir "$release_required_dir"
done

release_required_executables=(
    znc
    zagd
    zag-lsp
    bootstrap.sh
    tools/zagd-user-service.sh
    tools/zagd-launchd-service.sh
)
for release_required_executable in "${release_required_executables[@]}"; do
    release_require_executable "$release_required_executable"
done

manifest_version=""
if [ -f "$package_root/zag.mod" ]; then
    manifest_version=$(sed -n \
        's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"\([^"]*\)"[[:space:]]*$/\1/p' \
        "$package_root/zag.mod" | sed -n '1p')
fi
if [ "$manifest_version" != "$release_version" ]; then
    echo "release package: zag.mod version '$manifest_version' does not match '$release_version'" >&2
    release_package_fail=1
fi

forbidden_artifact=$(find "$package_root" \( \
    -name '*.zag.c' -o \
    -name '*.out' -o \
    -name '*.zag.zir.c' -o \
    -name '*.o' -o \
    -name '*.a' -o \
    -name '*.a.o' -o \
    -name '*.dylib' -o \
    -name '*.so' -o \
    -name '*.wasm' -o \
    -name '*.mlir' \
    \) -print | sed -n '1p')
if [ -n "$forbidden_artifact" ]; then
    echo "release package: forbidden generated artifact: $forbidden_artifact" >&2
    release_package_fail=1
fi
for retired_compiler_path in zagc selfhost/zagc selfhost/zagc.zag selfhost/codegen.zag; do
    if [ -e "$package_root/$retired_compiler_path" ]; then
        echo "release package: retired compiler artifact: $retired_compiler_path" >&2
        release_package_fail=1
    fi
done
release_debug_bundle=$(find "$package_root" -name '*.dSYM' -print | sed -n '1p')
if [ -n "$release_debug_bundle" ]; then
    echo "release package: generated debug bundle: $release_debug_bundle" >&2
    release_package_fail=1
fi
release_embedded_binary=""
while IFS= read -r -d '' release_candidate; do
    release_relative=${release_candidate#"$package_root/"}
    case "$release_relative" in
        znc|zagd|zag-lsp) continue ;;
    esac
    release_candidate_kind=$(file -b "$release_candidate" 2>/dev/null || true)
    case "$release_candidate_kind" in
        *ELF*|*Mach-O*|*'current ar archive'*|*WebAssembly*)
            release_embedded_binary="$release_relative"
            break
            ;;
    esac
done < <(find "$package_root" -type f -print0)
if [ -n "$release_embedded_binary" ]; then
    echo "release package: unexpected embedded binary: $release_embedded_binary" >&2
    release_package_fail=1
fi
if [ -e "$package_root/editors/vscode/node_modules" ]; then
    echo "release package: editor node_modules must not be archived" >&2
    release_package_fail=1
fi
if [ -e "$package_root/editors/vscode/zag-lang.vsix" ]; then
    echo "release package: stale nested VSIX must not be archived" >&2
    release_package_fail=1
fi
release_host_junk=$(find "$package_root" \( \
    -name '.DS_Store' -o \
    -name '.zag-cache' -o \
    -name '._*' \
    \) \
    -print | sed -n '1p')
if [ -n "$release_host_junk" ]; then
    echo "release package: host/cache debris must not be archived: $release_host_junk" >&2
    release_package_fail=1
fi

if [ "$release_package_fail" -ne 0 ]; then
    exit 1
fi
if [ "$layout_only" -eq 1 ]; then
    exit 0
fi

case "$(uname -s):$(uname -m)" in
    Darwin:arm64) release_host_platform=macos-arm64 ;;
    Linux:x86_64|Linux:amd64) release_host_platform=linux-x86_64 ;;
    Linux:aarch64|Linux:arm64) release_host_platform=linux-arm64 ;;
    *)
        echo "release package: unsupported validation host: $(uname -s) $(uname -m)" >&2
        exit 1
        ;;
esac
if [ "$release_host_platform" != "$release_platform" ]; then
    echo "release package: $release_platform archive cannot be validated on $release_host_platform" >&2
    exit 1
fi

. "$package_root/tests/portable.sh"
for release_binary in znc zagd zag-lsp; do
    if ! zag_assert_native_executable "$package_root/$release_binary"; then
        echo "release package: invalid $release_platform executable: $release_binary" >&2
        exit 1
    fi
done

/bin/bash -n \
    "$package_root/bootstrap.sh" \
    "$package_root/tools/zagd-user-service.sh" \
    "$package_root/tools/zagd-launchd-service.sh" \
    "$package_root/tests/check_release_package.sh"

release_validation_tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-package-check.XXXXXX")
release_validation_cleanup() { rm -rf "$release_validation_tmp"; }
trap release_validation_cleanup EXIT HUP INT TERM

# Parse the shipped Makefile and expand the complete install recipe without
# rebuilding or writing into the package. This catches missing install inputs.
make -C "$package_root" -n \
    DESTDIR="$release_validation_tmp/install-root" install \
    >"$release_validation_tmp/make-install.log"

compiler_version=$("$package_root/znc" version)
if [ "$compiler_version" != "$release_version" ]; then
    echo "release package: compiler version '$compiler_version' does not match '$release_version'" >&2
    exit 1
fi

release_smoke_target_args=()
case "$release_platform" in
    macos-arm64) release_smoke_target_args=(--target macos-arm64) ;;
    linux-arm64) release_smoke_target_args=(--target arm64) ;;
esac
(
    cd "$package_root"
    ./znc examples/numeric.zag "${release_smoke_target_args[@]}" \
        --no-zagd --no-analyze -o "$release_validation_tmp/numeric"
)
if ! zag_assert_native_executable "$release_validation_tmp/numeric"; then
    echo "release package: packaged compiler did not emit a native smoke executable" >&2
    exit 1
fi
release_smoke_output=$("$release_validation_tmp/numeric")
release_smoke_expected=$'2432902008176640000\n9900'
if [ "$release_smoke_output" != "$release_smoke_expected" ]; then
    echo "release package: packaged compiler smoke output mismatch" >&2
    exit 1
fi

trap - EXIT HUP INT TERM
release_validation_cleanup
echo "release package: $release_platform layout, install dry-run, and native smoke passed"
