#!/usr/bin/env bash
# Focused release archive contract: real source layout, candidate executables,
# checksum verification, and isolated PREFIX/DESTDIR installation. Never tags.
set -euo pipefail
cd "$(dirname "$0")/.."

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-release-package-test.XXXXXX")
ignored_mlir=examples/release-package-ignored-sentinel.mlir
ignored_exec=examples/release-package-ignored-sentinel.zag.out
cleanup() {
    rm -f -- "$ignored_mlir" "$ignored_exec"
    rm -rf -- "$tmp"
}
trap cleanup EXIT

version=$(sed -n 's/.*return "\([^"]*\)".*/\1/p' selfhost/version.zag | head -n 1)
[[ -n $version ]] || {
    echo 'release package test: cannot read source version' >&2
    exit 1
}

case $(uname -m) in
    x86_64|amd64) arch=x86_64; wrong_arch=aarch64 ;;
    aarch64|arm64) arch=aarch64; wrong_arch=x86_64 ;;
    *) echo "release package test: unsupported host architecture $(uname -m)" >&2; exit 1 ;;
esac

artifacts="$tmp/artifacts"
output_a="$tmp/output-a"
output_b="$tmp/output-b"
mkdir -p "$artifacts" "$output_a" "$output_b"
for tool in znc zagd zag-lsp; do
    # Exercise the real candidate artifacts: package validation must reject a
    # stale stack policy or wrong architecture before it can certify a release.
    [[ -x $tool ]] || {
        echo "release package test: candidate artifact is missing: $tool" >&2
        exit 1
    }
    cp "$tool" "$artifacts/$tool"
done

make_vsix() {
    local destination=$1 timestamp=$2 root
    root="$tmp/vsix-$timestamp"
    mkdir -p "$root/extension/out"
    printf '<PackageManifest/>\n' >"$root/extension.vsixmanifest"
    printf '<Types/>\n' >"$root/[Content_Types].xml"
    printf '{"name":"zag-lang","version":"0.0.0"}\n' >"$root/extension/package.json"
    printf 'fixture extension bundle\n' >"$root/extension/out/extension.js"
    printf 'Apache-2.0 fixture\n' >"$root/extension/LICENSE.txt"
    printf '%s\n' \
        'vscode-languageclient' 'vscode-languageserver-protocol' 'vscode-jsonrpc' \
        >"$root/extension/THIRD_PARTY_NOTICES.md"
    find "$root" -exec touch -d "$timestamp" {} +
    (cd "$root" && zip -X -q "$destination" \
        '[Content_Types].xml' extension.vsixmanifest extension/LICENSE.txt \
        extension/THIRD_PARTY_NOTICES.md extension/out/extension.js \
        extension/package.json)
}
vsix_a="$artifacts/zag-lang-a.vsix"
vsix_b="$artifacts/zag-lang-b.vsix"
make_vsix "$vsix_a" '2001-01-01 00:00:00 UTC'
make_vsix "$vsix_b" '2024-04-04 04:04:04 UTC'

[[ ! -e $ignored_mlir && ! -e $ignored_exec ]] || {
    echo 'release package test: ignored sentinel path already exists' >&2
    exit 1
}
git check-ignore -q "$ignored_mlir" && git check-ignore -q "$ignored_exec" || {
    echo 'release package test: sentinel paths are not ignored by policy' >&2
    exit 1
}
printf 'ignored MLIR must never ship\n' >"$ignored_mlir"
printf '#!/bin/sh\nexit 77\n' >"$ignored_exec"
chmod 755 "$ignored_exec"

tags_before=$(git for-each-ref --format='%(refname)%00%(objectname)' refs/tags | sha256sum)
(
    umask 002
    TZ=UTC SOURCE_DATE_EPOCH=$(git show -s --format=%ct HEAD) \
        bash release.sh --package-only "$version" "$arch" "$output_a" \
            "$artifacts" "$vsix_a"
)
(
    umask 077
    TZ=America/Los_Angeles SOURCE_DATE_EPOCH=$(git show -s --format=%ct HEAD) \
        bash release.sh --package-only "$version" "$arch" "$output_b" \
            "$artifacts" "$vsix_b"
)
tags_after=$(git for-each-ref --format='%(refname)%00%(objectname)' refs/tags | sha256sum)
[[ $tags_before == "$tags_after" ]] || {
    echo 'release package test: package-only changed a tag' >&2
    exit 1
}

tarname="zag-$version-$arch-linux"
archive="$output_a/$tarname.tar.gz"
checksum="$archive.sha256"
[[ -f $archive && -f $checksum ]] || {
    echo 'release package test: archive or checksum missing' >&2
    exit 1
}
[[ $(stat -c '%a' "$archive") == 644 && $(stat -c '%a' "$checksum") == 644 &&
   $(stat -c '%a' "$output_b/$tarname.tar.gz") == 644 &&
   $(stat -c '%a' "$output_b/$tarname.tar.gz.sha256") == 644 ]] || {
    echo 'release package test: published archive or checksum mode depends on umask' >&2
    exit 1
}
(cd "$output_a" && sha256sum -c "$(basename "$checksum")")
cmp "$archive" "$output_b/$tarname.tar.gz" || {
    echo 'release package test: normalized archives are not byte-identical' >&2
    exit 1
}

archive_list="$tmp/archive-list.txt"
tar -tzf "$archive" >"$archive_list"
if grep -Eq 'release-package-ignored-sentinel|gpu_vsa_hd\.mlir|/numeric$' "$archive_list"; then
    echo 'release package test: ignored build output leaked into archive' >&2
    exit 1
fi

extract="$tmp/extract"
package_root="$extract/$tarname"
install_root="$tmp/custom-prefix-root"
mkdir -p "$extract"
tar -xzf "$archive" --no-same-owner -C "$extract"

for required in \
    LICENSE Makefile release.sh RELEASE_COMMIT RELEASE_CANDIDATE \
    SOURCE_MANIFEST.sha256 \
    benchmarks/run_zagscript.sh tools/zagd-user-service.sh \
    docs/SUPPORT.md docs/DEPENDENCIES.md editors/vscode/zag-lang.vsix \
    editors/vscode/THIRD_PARTY_NOTICES.md
do
    [[ -e $package_root/$required ]] || {
        echo "release package test: missing $required" >&2
        exit 1
    }
done
[[ $(<"$package_root/RELEASE_COMMIT") == "$(git rev-parse HEAD)" ]]
(cd "$package_root" && sha256sum -c SOURCE_MANIFEST.sha256 >/dev/null)
[[ $(<"$package_root/RELEASE_CANDIDATE") == \
    "format=zag-release-candidate-v1
version=$version
arch=$arch
commit=$(git rev-parse HEAD)" ]] || {
    echo 'release package test: package-only candidate identity is malformed' >&2
    exit 1
}
unzip -tqq "$package_root/editors/vscode/zag-lang.vsix"
vsix_notices=$(unzip -p "$package_root/editors/vscode/zag-lang.vsix" \
    extension/THIRD_PARTY_NOTICES.md)
grep -q vscode-languageclient <<<"$vsix_notices"

if find "$package_root" -perm /0022 -print -quit | grep -q .; then
    echo 'release package test: archive contains group- or other-writable content' >&2
    exit 1
fi
for executable in znc zagd zag-lsp bootstrap.sh release.sh tools/zagd-user-service.sh; do
    [[ $(stat -c '%a' "$package_root/$executable") == 755 ]] || {
        echo "release package test: wrong executable mode for $executable" >&2
        exit 1
    }
done

# Exercise non-default PREFIX and DESTDIR from the extracted archive. The
# candidate artifacts are copied into the custom root; the
# Makefile target has no build prerequisite and must not bootstrap them.
make -C "$package_root" --no-print-directory install-only \
    PREFIX=/opt/zag DESTDIR="$install_root"
for installed in \
    opt/zag/bin/znc opt/zag/bin/zagd opt/zag/bin/zag-lsp \
    opt/zag/bin/zagd-user-service opt/zag/lib/zag/std/process.zag \
    opt/zag/share/zag/zagd.conf.example
do
    [[ -e $install_root/$installed ]] || {
        echo "release package test: custom-prefix install missing $installed" >&2
        exit 1
    }
done

if find "$package_root" \( -type l -o -name node_modules -o -name .zag-cache \) \
    -print -quit | grep -q .; then
    echo 'release package test: unsafe or generated path leaked into archive' >&2
    exit 1
fi

if SOURCE_DATE_EPOCH=$(git show -s --format=%ct HEAD) \
    bash release.sh --package-only "$version" "$wrong_arch" "$tmp/wrong-arch" \
        "$artifacts" "$vsix_a" >"$tmp/wrong-arch.log" 2>&1; then
    echo 'release package test: wrong-architecture artifacts were accepted' >&2
    exit 1
fi
grep -q 'machine does not match' "$tmp/wrong-arch.log"

printf 'not a zip\n' >"$tmp/bogus.vsix"
if SOURCE_DATE_EPOCH=$(git show -s --format=%ct HEAD) \
    bash release.sh --package-only "$version" "$arch" "$tmp/bogus-vsix" \
        "$artifacts" "$tmp/bogus.vsix" >"$tmp/bogus-vsix.log" 2>&1; then
    echo 'release package test: bogus VSIX was accepted' >&2
    exit 1
fi
grep -q 'not a valid ZIP' "$tmp/bogus-vsix.log"

# The dry-run shares the real pair verifier but must refuse a renamed copy of
# one architecture as the other and must never mutate refs/tags.
pair_dir="$tmp/pair-negative"
mkdir -p "$pair_dir"
fake_other="$pair_dir/zag-$version-$wrong_arch-linux.tar.gz"
cp "$archive" "$fake_other"
(cd "$pair_dir" && sha256sum "$(basename "$fake_other")" \
    >"$(basename "$fake_other").sha256")
tags_before_dry_run=$(git for-each-ref --format='%(refname)%00%(objectname)' \
    refs/tags | sha256sum)
if [[ $arch == x86_64 ]]; then
    dry_x86=$archive
    dry_arm=$fake_other
else
    dry_x86=$fake_other
    dry_arm=$archive
fi
if bash release.sh --finalize-dry-run "$version" "$dry_x86" "$dry_arm" \
    >"$tmp/pair-negative.log" 2>&1; then
    echo 'release package test: dry-run accepted a forged two-architecture pair' >&2
    exit 1
fi
grep -Eq 'single release root|machine does not match|candidate identity' \
    "$tmp/pair-negative.log"
tags_after_dry_run=$(git for-each-ref --format='%(refname)%00%(objectname)' \
    refs/tags | sha256sum)
[[ $tags_before_dry_run == "$tags_after_dry_run" ]] || {
    echo 'release package test: finalization dry-run changed a tag' >&2
    exit 1
}

echo 'release package contract: PASS (reproducible tracked archive + checksum + isolated install, no tag)'
