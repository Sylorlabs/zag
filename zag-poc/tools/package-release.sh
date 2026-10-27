#!/usr/bin/env bash
# Assemble and test a native distribution without committing, tagging,
# publishing, installing globally, or replacing any checkout tool.
# Qualification/release authorization remains the caller's responsibility.
set -euo pipefail

if [ "$#" -ne 6 ]; then
    echo "usage: $0 VERSION PLATFORM COMPILER DAEMON VSIX OUTPUT_DIRECTORY" >&2
    exit 2
fi
package_version=$1
package_platform=$2
package_compiler=$3
package_daemon=$4
package_vsix=$5
package_output=$6
if [[ ! $package_version =~ ^[0-9][0-9A-Za-z._-]*$ ]]; then
    echo 'package: version must be one safe path component' >&2
    exit 2
fi
case "$package_compiler" in /*) ;; *) package_compiler="$PWD/$package_compiler" ;; esac
case "$package_daemon" in /*) ;; *) package_daemon="$PWD/$package_daemon" ;; esac
case "$package_vsix" in /*) ;; *) package_vsix="$PWD/$package_vsix" ;; esac
if [ ! -d "$package_output" ]; then
    echo 'package: output directory must already exist' >&2
    exit 2
fi
package_output=$(cd "$package_output" && pwd -P)
cd "$(dirname "$0")/.."
package_source=$PWD
. ./tests/portable.sh

package_target_args=()
case "$(uname -s):$(uname -m)" in
    Darwin:arm64) package_host=macos-arm64; package_target_args=(--target macos-arm64) ;;
    Linux:x86_64|Linux:amd64) package_host=linux-x86_64 ;;
    Linux:aarch64|Linux:arm64) package_host=linux-arm64; package_target_args=(--target arm64) ;;
    *) echo 'package: unsupported native host' >&2; exit 2 ;;
esac
if [ "$package_platform" != "$package_host" ]; then
    echo "package: cannot validate $package_platform artifacts on $package_host" >&2
    exit 2
fi
for package_binary in "$package_compiler" "$package_daemon"; do
    test -x "$package_binary"
    zag_assert_native_executable "$package_binary"
done
package_manifest_version=$(sed -n \
    's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"\([^"]*\)"[[:space:]]*$/\1/p' \
    zag.mod | sed -n '1p')
if [ "$package_manifest_version" != "$package_version" ] ||
   [ "$(zag_compiler_version "$package_compiler")" != "$package_version" ]; then
    echo 'package: compiler, manifest, and requested versions must agree' >&2
    exit 1
fi
if ! command -v unzip >/dev/null || ! unzip -tq "$package_vsix" >/dev/null ||
   ! unzip -p "$package_vsix" extension/out/extension.js |
       awk 'index($0, "vscode-languageclient") { found=1 } END { exit !found }' ||
   ! unzip -p "$package_vsix" extension/out/extension.js |
       awk 'index($0, "zag-lsp") { found=1 } END { exit !found }'; then
    echo 'package: a valid, bundled VS Code client is required' >&2
    exit 1
fi

package_name="zag-$package_version-$package_platform"
package_archive="$package_output/$package_name.tar.gz"
package_checksum="$package_archive.sha256"
for package_destination in "$package_archive" "$package_checksum"; do
    if [ -e "$package_destination" ] || [ -L "$package_destination" ]; then
        echo "package: refusing to replace $package_destination" >&2
        exit 1
    fi
done
# Stage on the destination filesystem so publication can use no-clobber hard
# links. Every cleanup below is restricted to this freshly allocated tree.
package_work=$(mktemp -d "$package_output/.zag-package.XXXXXX")
package_staging="$package_work/$package_name"
package_checksum_published=0
package_complete=0
package_cleanup() {
    if [ "$package_complete" -eq 0 ] && [ "$package_checksum_published" -eq 1 ] &&
       [ "$package_checksum" -ef "$package_work/archive.sha256" ]; then
        rm -f "$package_checksum"
    fi
    rm -rf "$package_work"
}
trap package_cleanup EXIT
trap 'exit 130' HUP INT TERM
mkdir "$package_staging"

# Copy source, including untracked development source, but not host caches or
# editor dependency trees. Only temporary copies are cleaned below.
COPYFILE_DISABLE=1 tar --no-xattrs \
    --exclude='.zag-cache' --exclude='.zagd.status' --exclude='.zagd.lock' \
    --exclude='.zagd.semantic-ready' --exclude='.DS_Store' \
    --exclude='._*' --exclude='*.dSYM' -cf - \
    examples programs tests selfhost std tools docs |
    COPYFILE_DISABLE=1 tar --no-xattrs -xf - -C "$package_staging"
package_editor_parent="$package_source/.."
package_license="$package_source/../LICENSE"
if [ -d "$package_source/editors" ]; then
    package_editor_parent="$package_source"
    package_license="$package_source/LICENSE"
fi
(
    cd "$package_editor_parent"
    COPYFILE_DISABLE=1 tar --no-xattrs --exclude='node_modules' \
        --exclude='editors/vscode/out' --exclude='editors/vscode/zag-lang.vsix' \
        --exclude='.DS_Store' --exclude='._*' -cf - editors
) | COPYFILE_DISABLE=1 tar --no-xattrs -xf - -C "$package_staging"
cp Makefile zag.mod bootstrap.sh README.md BOOTSTRAP.md INSTALL.md CHANGELOG.md \
    COMPATIBILITY.md NATIVE_BOOTSTRAP_REPRODUCIBILITY.md RELEASES.md VERSIONING.md \
    "$package_staging/"
cp "$package_license" "$package_staging/LICENSE"

# Ignored extensionless test executables are just as stale as *.out. Detect
# their actual format, rather than trusting a filename or Git's tracked set.
find "$package_staging" -type f \( \
    -name '*.zag.c' -o -name '*.out' -o -name '*.zag.zir.c' -o \
    -name '*.o' -o -name '*.a' -o -name '*.dylib' -o -name '*.so' -o \
    -name '*.wasm' -o -name '*.mlir' \) -delete
while IFS= read -r -d '' package_candidate; do
    case "$(file -b "$package_candidate")" in
        *ELF*|*Mach-O*|*'current ar archive'*|*WebAssembly*) rm -f "$package_candidate" ;;
    esac
done < <(find "$package_staging" -type f -print0)

cp "$package_compiler" "$package_staging/znc"
cp "$package_daemon" "$package_staging/zagd"
cp "$package_vsix" "$package_staging/zag-lang.vsix"
printf '%s  znc\n' "$(zag_sha256_file "$package_staging/znc")" \
    >"$package_staging/znc.sha256"
# Build the editor server from the same staged source that users receive.
(
    cd "$package_staging"
    zag_run_bounded 600 ./znc selfhost/lsp/zag-lsp.zag \
        ${package_target_args[@]+"${package_target_args[@]}"} \
        --no-zagd --no-analyze --no-foreground-cache -o zag-lsp
)
# Checking a compilation still publishes advisory semantic records even when
# machine caching and the daemon are disabled. Remove only the records from
# this fresh staging build; they are not distribution inputs.
rm -rf "$package_staging/.zag-cache"
rm -f "$package_staging/.zagd.semantic-ready"
bash "$package_staging/tests/check_release_package.sh" \
    "$package_staging" "$package_platform" "$package_version"

COPYFILE_DISABLE=1 tar --no-xattrs -czf "$package_work/archive.tar.gz" \
    -C "$package_work" "$package_name"
mkdir "$package_work/extracted"
COPYFILE_DISABLE=1 tar --no-xattrs -xzf "$package_work/archive.tar.gz" \
    -C "$package_work/extracted"
package_extracted="$package_work/extracted/$package_name"
if ! diff -qr "$package_staging" "$package_extracted" >"$package_work/archive.diff"; then
    echo 'package: extracted archive differs from the staged tree' >&2
    sed -n '1,80p' "$package_work/archive.diff" >&2
    exit 1
fi
bash "$package_extracted/tests/check_release_package.sh" \
    "$package_extracted" "$package_platform" "$package_version"
printf '%s  %s.tar.gz\n' "$(zag_sha256_file "$package_work/archive.tar.gz")" \
    "$package_name" >"$package_work/archive.sha256"
ln "$package_work/archive.sha256" "$package_checksum"
package_checksum_published=1
ln "$package_work/archive.tar.gz" "$package_archive"
package_complete=1
echo "package: validated native archive $package_archive"
echo "package: checksum $package_checksum"
