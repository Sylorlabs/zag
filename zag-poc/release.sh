#!/usr/bin/env bash
# release.sh — verify, package, and sign a Zag release
#
# Host candidate:      ./release.sh 2026.07.0
# Final signed tag:    ./release.sh --finalize VERSION X86_ARCHIVE ARM64_ARCHIVE
# Package-contract CI: ./release.sh --package-only VERSION ARCH OUT ARTIFACTS VSIX
#
# Candidate mode never tags. Finalization accepts both independently built host
# archives, verifies them against one clean source commit, reruns the canonical
# closure, and creates one signed tag binding both hashes.
set -euo pipefail
cd "$(dirname "$0")"
export LC_ALL=C
export ZNC="$PWD/znc"

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat >&2 <<'USAGE'
usage:
  ./release.sh YYYY.MM.PATCH
  ./release.sh --finalize VERSION X86_64_ARCHIVE AARCH64_ARCHIVE
  ./release.sh --finalize-dry-run VERSION X86_64_ARCHIVE AARCH64_ARCHIVE
  ./release.sh --package-only VERSION ARCH OUTPUT_DIR ARTIFACT_DIR VSIX

The one-argument form is a gated convenience for a host that already has the
matching trusted native seed and tools. It builds that host's candidate without
tagging. CI and native-AArch64 jobs should use the explicit --package-only path
after producing their separately verified architecture artifacts.

--package-only creates one explicit per-architecture candidate and exercises
the real archive and staged-install path, but does not run release gates,
require a clean developer tree, create a tag, or publish.
ARCH must be x86_64 or aarch64. ARTIFACT_DIR must contain executable znc,
zagd, and zag-lsp files. --finalize-dry-run exercises the same two-candidate
structure, checksum, source, architecture, and install verifier as --finalize,
but deliberately skips the release gate, source rebuild, and signed tag.
USAGE
    exit 2
}

source_version() {
    sed -n 's/.*return "\([^"]*\)".*/\1/p' selfhost/version.zag | head -n 1
}

module_version() {
    awk '$1 == "version" && $2 == "=" { gsub(/"/, "", $3); print $3; exit }' zag.mod
}

validate_versioned_source() {
    local requested=$1
    local compiler_version module_manifest_version
    compiler_version=$(source_version)
    module_manifest_version=$(module_version)
    [[ $compiler_version == "$requested" ]] ||
        die "selfhost/version.zag reports '$compiler_version', not '$requested'."
    [[ $module_manifest_version == "$requested" ]] ||
        die "zag.mod reports '$module_manifest_version', not '$requested'."
}

assert_clean_worktree() {
    if [[ -n $(git status --porcelain --untracked-files=all) ]]; then
        die 'release requires a completely clean worktree, including untracked files.'
    fi
    git diff --check
}

require_file() {
    [[ -f $1 ]] || die "required release input is missing: $1"
}

require_executable() {
    [[ -f $1 && -x $1 ]] || die "required executable release input is missing: $1"
}

validate_release_elf() {
    local path=$1 arch=$2 header phdrs expected_machine stack_count
    command -v readelf >/dev/null 2>&1 || die 'readelf is required to validate release artifacts.'
    [[ ! -L $path ]] || die "release artifact must not be a symlink: $path"
    header=$(LC_ALL=C readelf -hW "$path" 2>/dev/null) || die "release artifact is not a readable ELF file: $path"
    grep -Eq '^  Class:[[:space:]]+ELF64$' <<<"$header" ||
        die "release artifact is not ELF64: $path"
    grep -Eq '^  Type:[[:space:]]+EXEC ' <<<"$header" ||
        die "release artifact is not an executable ELF image: $path"
    case $arch in
        x86_64) expected_machine='Advanced Micro Devices X86-64' ;;
        aarch64) expected_machine='AArch64' ;;
        *) die "unsupported artifact architecture: $arch" ;;
    esac
    [[ $(awk -F: '$1 ~ /Machine/ { sub(/^[[:space:]]+/, "", $2); print $2; exit }' \
        <<<"$header") == "$expected_machine" ]] ||
            die "release artifact machine does not match $arch: $path"
    phdrs=$(LC_ALL=C readelf -lW "$path" 2>/dev/null) ||
        die "cannot inspect release artifact program headers: $path"
    stack_count=$(awk '$1 == "GNU_STACK" { count++ } END { print count+0 }' <<<"$phdrs")
    [[ $stack_count -eq 1 ]] || die "release artifact lacks one explicit GNU_STACK policy: $path"
    awk '$1 == "GNU_STACK" && $0 ~ /RW/ && $0 !~ /RWE/ { ok=1 } END { exit(ok ? 0 : 1) }' \
        <<<"$phdrs" || die "release artifact requests an executable stack: $path"
    ! awk '$1 == "LOAD" && ($0 ~ /RWE/ || $0 ~ /W E/) { bad=1 } END { exit(bad ? 0 : 1) }' \
        <<<"$phdrs" || die "release artifact contains a writable executable LOAD: $path"
}

validate_vsix() {
    local path=$1 listing required notices
    command -v unzip >/dev/null 2>&1 || die 'unzip is required to validate VSIX artifacts.'
    unzip -tqq "$path" >/dev/null || die "VSIX is not a valid ZIP archive: $path"
    listing=$(unzip -Z1 "$path")
    for required in \
        extension.vsixmanifest '[Content_Types].xml' extension/package.json \
        extension/LICENSE.txt extension/THIRD_PARTY_NOTICES.md extension/out/extension.js
    do
        grep -Fxq "$required" <<<"$listing" || die "VSIX is missing required member: $required"
    done
    notices=$(unzip -p "$path" extension/THIRD_PARTY_NOTICES.md)
    for required in vscode-languageclient vscode-languageserver-protocol vscode-jsonrpc; do
        grep -Fq "$required" <<<"$notices" || die "VSIX notices omit bundled dependency: $required"
    done
}

copy_tracked_release_trees() {
    local staging=$1 tracked_list
    tracked_list="$PACKAGE_TMP/tracked-release-files"
    git ls-files -z -- benchmarks examples programs selfhost std tests docs tools >"$tracked_list"
    [[ -s $tracked_list ]] || die 'tracked release source manifest is empty.'
    # Copy only Git-known project inputs. A clean-worktree check does not report
    # ignored binaries, MLIR, caches, or other generated files, so recursively
    # copying the live directories would make release contents workstation-
    # dependent even from an otherwise clean checkout.
    tar --null --verbatim-files-from --no-recursion -T "$tracked_list" -cf - |
        tar -xf - -C "$staging"
}

copy_tracked_editor_syntaxes() {
    local staging=$1 source rel
    while IFS= read -r -d '' source; do
        rel=${source#../editors/vscode/}
        [[ $rel != "$source" && $rel == syntaxes/* ]] ||
            die "unexpected editor syntax path in Git manifest: $source"
        mkdir -p "$staging/editors/vscode/$(dirname "$rel")"
        install -m644 "$source" "$staging/editors/vscode/$rel"
    done < <(git ls-files -z -- ../editors/vscode/syntaxes)
}

normalize_vsix() {
    local source=$1 destination=$2 epoch=$3 unpack forbidden path
    local -a files=()
    command -v zip >/dev/null 2>&1 || die 'zip is required to normalize VSIX metadata.'
    command -v unzip >/dev/null 2>&1 || die 'unzip is required to normalize VSIX metadata.'
    validate_vsix "$source"
    unpack="$PACKAGE_TMP/vsix-unpacked"
    rm -rf -- "$unpack"
    mkdir -p "$unpack"
    unzip -qq "$source" -d "$unpack"
    forbidden=$(find "$unpack" -type l -print -quit)
    [[ -z $forbidden ]] || die "VSIX contains a symlink: $forbidden"
    find "$unpack" -type d -exec chmod 755 {} +
    find "$unpack" -type f -exec chmod 644 {} +
    find "$unpack" -exec touch -h -d "@$epoch" {} +
    while IFS= read -r -d '' path; do files+=("${path#./}"); done \
        < <(cd "$unpack" && find . -type f -print0 | LC_ALL=C sort -z)
    [[ ${#files[@]} -gt 0 ]] || die 'VSIX contains no regular files.'
    rm -f -- "$destination"
    (cd "$unpack" && TZ=UTC LC_ALL=C zip -X -q "$destination" "${files[@]}")
}

normalize_staging_modes() {
    local staging=$1 record mode path
    find "$staging" -type d -exec chmod 755 {} +
    find "$staging" -type f -exec chmod 644 {} +
    # Restore only Git's executable bit for tracked project files. This maps
    # Git's portable 100644/100755 model to deterministic archive modes.
    while IFS= read -r -d '' record; do
        mode=${record%% *}
        path=${record#*$'\t'}
        if [[ $mode == 100755 && -f $staging/$path ]]; then
            chmod 755 "$staging/$path"
        fi
    done < <(git ls-files -z --stage -- benchmarks examples programs selfhost std tests docs tools)
    chmod 755 "$staging/znc" "$staging/zagd" "$staging/zag-lsp" \
        "$staging/bootstrap.sh" "$staging/release.sh" \
        "$staging/tools/zagd-user-service.sh"
}

PACKAGE_TMP=
RELEASE_BUILD_TMP=
cleanup_release_tmp() {
    if [[ -n $PACKAGE_TMP && -d $PACKAGE_TMP ]]; then
        rm -rf -- "$PACKAGE_TMP"
    fi
    if [[ -n $RELEASE_BUILD_TMP && -d $RELEASE_BUILD_TMP ]]; then
        rm -rf -- "$RELEASE_BUILD_TMP"
    fi
}
trap cleanup_release_tmp EXIT

generate_source_manifest() {
    local root=$1 output=$2
    (
        cd "$root"
        find . -type f \
            ! -path './znc' ! -path './zagd' ! -path './zag-lsp' \
            ! -path './RELEASE_CANDIDATE' \
            ! -path './editors/vscode/zag-lang.vsix' \
            ! -path './SOURCE_MANIFEST.sha256' -print0 |
            LC_ALL=C sort -z |
            while IFS= read -r -d '' path; do sha256sum "$path"; done
    ) >"$output"
}

generate_checkout_source_manifest() {
    local expected_commit=$1 output=$2 path_list rel local_path hash source
    path_list="$PACKAGE_TMP/expected-checkout-paths"
    {
        printf '%s\0' \
            LICENSE RELEASE_COMMIT README.md BOOTSTRAP.md INSTALL.md \
            CHANGELOG.md VERSIONING.md COMPATIBILITY.md RELEASES.md \
            NATIVE_BOOTSTRAP_REPRODUCIBILITY.md Makefile zag.mod \
            bootstrap.sh release.sh \
            docs/SUPPORT.md docs/DEPENDENCIES.md \
            editors/vscode/.gitignore editors/vscode/LICENSE.txt \
            editors/vscode/README.md editors/vscode/THIRD_PARTY_NOTICES.md \
            editors/vscode/extension.ts \
            editors/vscode/language-configuration.json \
            editors/vscode/package-lock.json editors/vscode/package.json \
            editors/vscode/tsconfig.json
        git ls-files -z -- benchmarks examples programs selfhost std tests docs tools
        while IFS= read -r -d '' source; do
            printf '%s\0' "${source#../}"
        done < <(git ls-files -z -- ../editors/vscode/syntaxes)
    } | sort -zu >"$path_list"

    : >"$output"
    while IFS= read -r -d '' rel; do
        case "/$rel/" in
            */node_modules/*|*/.zag-cache/*|*/.git/*|*/__pycache__/*|*/target/*)
                continue
                ;;
        esac
        case $rel in
            *.zag.c|*.zag.out|*.zag.zir.c|*.o) continue ;;
            RELEASE_COMMIT)
                hash=$(printf '%s\n' "$expected_commit" | sha256sum | awk '{ print $1 }')
                ;;
            LICENSE) local_path=../LICENSE ;;
            editors/vscode/*) local_path="../$rel" ;;
            *) local_path=$rel ;;
        esac
        if [[ $rel != RELEASE_COMMIT ]]; then
            [[ -f $local_path && ! -L $local_path ]] ||
                die "required checkout source is not a regular file: $rel"
            hash=$(sha256sum "$local_path" | awk '{ print $1 }')
        fi
        printf '%s  ./%s\n' "$hash" "$rel" >>"$output"
    done <"$path_list"
}

verify_manifest_against_checkout() {
    local root=$1 expected_commit=$2 line hash rel local_path actual
    while IFS= read -r line; do
        hash=${line%% *}
        rel=${line#*  }
        [[ $hash =~ ^[0-9a-f]{64}$ && $rel == ./* ]] ||
            die "malformed source-manifest entry in $root: $line"
        rel=${rel#./}
        case $rel in
            RELEASE_COMMIT)
                [[ $(<"$root/$rel") == "$expected_commit" ]] ||
                    die "archive release commit does not match $expected_commit"
                continue
                ;;
            LICENSE) local_path=../LICENSE ;;
            editors/vscode/*) local_path="../$rel" ;;
            *) local_path=$rel ;;
        esac
        [[ -f $local_path && ! -L $local_path ]] ||
            die "archive manifest path has no regular checkout source: $rel"
        actual=$(sha256sum "$local_path" | awk '{ print $1 }')
        [[ $actual == "$hash" ]] ||
            die "archive source differs from the finalizing checkout: $rel"
    done <"$root/SOURCE_MANIFEST.sha256"
}

verify_archive() {
    local archive=$1
    local checksum=$2
    local tarname=$3
    local arch=$4
    local expected_commit=$5
    local expected_version=$6
    local verify_dir member root install_root forbidden recomputed_manifest
    local member_list sorted_members duplicate_members duplicate_member root_count
    local expected_manifest type_field owner_field date_field time_field
    local expected_epoch expected_stamp
    local recorded_hash actual_hash embedded_version embedded_module_version path

    require_file "$archive"
    require_file "$checksum"
    recorded_hash=$(awk -v name="$(basename "$archive")" \
        'NF { lines++ } $2 == name && length($1) == 64 && $1 !~ /[^0-9a-f]/ { print $1; count++ } END { if (lines != 1 || count != 1) exit 1 }' \
        "$checksum") || die "checksum sidecar must contain exactly one record for $(basename "$archive")"
    actual_hash=$(sha256sum "$archive" | awk '{ print $1 }')
    [[ $actual_hash == "$recorded_hash" ]] || die "archive checksum mismatch: $archive"
    VERIFIED_ARCHIVE_HASH=$actual_hash
    expected_epoch=$(git show -s --format=%ct "$expected_commit")
    expected_stamp=$(date -u -d "@$expected_epoch" '+%Y-%m-%d %H:%M:%S')

    verify_dir="$PACKAGE_TMP/verify-$arch"
    mkdir -p "$verify_dir"
    member_list="$PACKAGE_TMP/archive-members-$arch"
    sorted_members="$PACKAGE_TMP/archive-members-sorted-$arch"
    duplicate_members="$PACKAGE_TMP/archive-members-duplicates-$arch"
    tar -tzf "$archive" >"$member_list"
    [[ -s $member_list ]] || die "archive has no members: $archive"
    sort "$member_list" >"$sorted_members"
    uniq -d "$sorted_members" >"$duplicate_members"
    duplicate_member=$(sed -n '1p' "$duplicate_members")
    [[ -z $duplicate_member ]] || die "archive contains duplicate member: $duplicate_member"
    root_count=$(grep -Fxc "$tarname/" "$member_list" || true)
    [[ $root_count -eq 1 ]] || die "archive must contain exactly one explicit release root: $archive"
    while IFS= read -r member; do
        case "$member" in
            "$tarname"|"$tarname/"|"$tarname/"*) ;;
            *) die "archive member escapes the single release root: $member" ;;
        esac
        case "/$member/" in
            */../*|*/./*) die "archive contains an unsafe path component: $member" ;;
        esac
    done <"$member_list"
    while read -r type_field owner_field _ date_field time_field _; do
        case ${type_field:0:1} in
            -|d) ;;
            *) die "archive contains a non-regular, non-directory member: $archive" ;;
        esac
        case $type_field in
            drwxr-xr-x|-rw-r--r--|-rwxr-xr-x) ;;
            *) die "archive member has a non-normalized mode: $type_field in $archive" ;;
        esac
        [[ $owner_field == 0/0 ]] || die "archive member is not owned by numeric 0/0: $archive"
        [[ "$date_field $time_field" == "$expected_stamp" ]] ||
            die "archive member timestamp does not match the source commit: $archive"
    done < <(TZ=UTC tar --numeric-owner --full-time -tvzf "$archive")
    tar -xzf "$archive" --no-same-owner -C "$verify_dir"
    root="$verify_dir/$tarname"

    for required in \
        LICENSE README.md BOOTSTRAP.md INSTALL.md CHANGELOG.md VERSIONING.md \
        COMPATIBILITY.md RELEASES.md NATIVE_BOOTSTRAP_REPRODUCIBILITY.md \
        Makefile release.sh bootstrap.sh zag.mod RELEASE_COMMIT \
        SOURCE_MANIFEST.sha256 znc zagd zag-lsp \
        tools/zagd-user-service.sh examples/zagd.conf \
        docs/SUPPORT.md docs/DEPENDENCIES.md \
        editors/vscode/zag-lang.vsix editors/vscode/THIRD_PARTY_NOTICES.md
    do
        [[ -e $root/$required ]] ||
            die "verified archive is missing required path: $required"
    done
    for required_dir in benchmarks examples programs selfhost std tests docs tools editors; do
        [[ -d $root/$required_dir ]] ||
            die "verified archive is missing required directory: $required_dir"
    done
    for executable in znc zagd zag-lsp bootstrap.sh release.sh tools/zagd-user-service.sh; do
        [[ -x $root/$executable ]] ||
            die "verified archive path is not executable: $executable"
    done
    require_file "$root/RELEASE_CANDIDATE"
    [[ $(<"$root/RELEASE_CANDIDATE") == \
        "format=zag-release-candidate-v1
version=$expected_version
arch=$arch
commit=$expected_commit" ]] ||
        die "archive lacks the exact per-architecture candidate identity: $archive"

    forbidden=$(find "$root" \( \
        -type l -o \
        -name node_modules -o -name .zag-cache -o -name .git -o \
        -name '*.zag.c' -o -name '*.zag.out' -o -name '*.zag.zir.c' -o \
        -name '*.o' \
    \) -print -quit)
    [[ -z $forbidden ]] || die "forbidden generated or unsafe archive path: $forbidden"

    for path in znc zagd zag-lsp; do
        validate_release_elf "$root/$path" "$arch"
    done
    validate_vsix "$root/editors/vscode/zag-lang.vsix"
    embedded_version=$(sed -n 's/.*return "\([^"]*\)".*/\1/p' \
        "$root/selfhost/version.zag" | head -n 1)
    embedded_module_version=$(awk '$1 == "version" && $2 == "=" { gsub(/"/, "", $3); print $3; exit }' \
        "$root/zag.mod")
    [[ $embedded_version == "$expected_version" && $embedded_module_version == "$expected_version" ]] ||
        die "archive source version does not match $expected_version: $archive"
    [[ $(<"$root/RELEASE_COMMIT") == "$expected_commit" ]] ||
        die "archive was not built from release commit $expected_commit: $archive"

    recomputed_manifest="$PACKAGE_TMP/recomputed-manifest-$arch"
    generate_source_manifest "$root" "$recomputed_manifest"
    cmp -s "$root/SOURCE_MANIFEST.sha256" "$recomputed_manifest" ||
        die "archive source manifest is incomplete or inconsistent: $archive"
    (cd "$root" && sha256sum -c SOURCE_MANIFEST.sha256 >/dev/null)
    expected_manifest="$PACKAGE_TMP/expected-checkout-manifest"
    generate_checkout_source_manifest "$expected_commit" "$expected_manifest"
    cmp -s "$root/SOURCE_MANIFEST.sha256" "$expected_manifest" ||
        die "archive source manifest is not the complete finalizing checkout manifest: $archive"
    verify_manifest_against_checkout "$root" "$expected_commit"

    # This is a real copy-only install into an isolated package root. It proves
    # that the archive contains every file consumed by Makefile install-only
    # without touching /usr/local and without invoking the compiler.
    install_root="$PACKAGE_TMP/install-root-$arch"
    make -C "$root" --no-print-directory install-only \
        PREFIX=/usr/local DESTDIR="$install_root"
    for installed in \
        usr/local/bin/znc usr/local/bin/zagd usr/local/bin/zag-lsp \
        usr/local/bin/zagd-user-service \
        usr/local/lib/zag/std/process.zag \
        usr/local/share/zag/zagd.conf.example
    do
        [[ -e $install_root/$installed ]] ||
            die "staged install is missing: $installed"
    done
    VERIFIED_ROOT=$root
}

package_archive() {
    local version=$1
    local arch=$2
    local output_dir=$3
    local artifact_dir=$4
    local vsix=$5
    local tarname staging archive checksum source_date_epoch commit_epoch forbidden release_commit
    local path

    [[ $version =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]] ||
        die 'package version must be a safe CalVer value.'
    [[ $(uname -s) == Linux ]] || die "release packaging supports Linux hosts only, not $(uname -s)."
    case "$arch" in x86_64|aarch64) ;; *) die "unsupported package architecture: $arch" ;; esac
    validate_versioned_source "$version"
    for path in znc zagd zag-lsp; do
        require_executable "$artifact_dir/$path"
        validate_release_elf "$artifact_dir/$path" "$arch"
    done
    require_file "$vsix"
    validate_vsix "$vsix"
    require_file ../LICENSE
    require_file docs/SUPPORT.md
    require_file docs/DEPENDENCIES.md

    mkdir -p "$output_dir"
    output_dir=$(cd "$output_dir" && pwd -P)
    tarname="zag-$version-$arch-linux"
    archive="$output_dir/$tarname.tar.gz"
    checksum="$archive.sha256"
    [[ ! -e $archive && ! -e $checksum ]] ||
        die "refusing to overwrite existing release output: $archive"

    commit_epoch=$(git show -s --format=%ct HEAD)
    source_date_epoch=${SOURCE_DATE_EPOCH:-$commit_epoch}
    [[ $source_date_epoch =~ ^[0-9]+$ ]] || die 'SOURCE_DATE_EPOCH must be numeric.'
    [[ $source_date_epoch == "$commit_epoch" ]] ||
        die 'SOURCE_DATE_EPOCH must equal the release commit timestamp.'
    release_commit=$(git rev-parse HEAD)

    PACKAGE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/zag-release-package.XXXXXX")
    staging="$PACKAGE_TMP/$tarname"
    mkdir -p "$staging/editors/vscode"

    install -m755 "$artifact_dir/znc" "$staging/znc"
    install -m755 "$artifact_dir/zagd" "$staging/zagd"
    install -m755 "$artifact_dir/zag-lsp" "$staging/zag-lsp"
    install -m755 bootstrap.sh release.sh "$staging/"
    install -m644 ../LICENSE "$staging/LICENSE"
    printf '%s\n' "$release_commit" >"$staging/RELEASE_COMMIT"
    printf 'format=zag-release-candidate-v1\nversion=%s\narch=%s\ncommit=%s\n' \
        "$version" "$arch" "$release_commit" >"$staging/RELEASE_CANDIDATE"
    install -m644 \
        README.md BOOTSTRAP.md INSTALL.md CHANGELOG.md VERSIONING.md \
        COMPATIBILITY.md RELEASES.md NATIVE_BOOTSTRAP_REPRODUCIBILITY.md \
        Makefile zag.mod "$staging/"

    copy_tracked_release_trees "$staging"
    # These authority documents are mandatory. Normal release mode's clean-tree
    # rule also requires them to be tracked; explicit copies let package-only
    # exercise a candidate before its final commit.
    mkdir -p "$staging/docs"
    install -m644 docs/SUPPORT.md docs/DEPENDENCIES.md "$staging/docs/"

    for path in \
        .gitignore LICENSE.txt README.md THIRD_PARTY_NOTICES.md extension.ts \
        language-configuration.json package-lock.json package.json tsconfig.json
    do
        require_file "../editors/vscode/$path"
        install -m644 "../editors/vscode/$path" "$staging/editors/vscode/$path"
    done
    copy_tracked_editor_syntaxes "$staging"
    normalize_vsix "$vsix" "$staging/editors/vscode/zag-lang.vsix" \
        "$source_date_epoch"

    # Never let workstation caches, absolute symlinks, or generated compiler
    # products leak into a release, even when package-only is testing a dirty
    # checkout. The normal release's clean-tree check remains mandatory too.
    find "$staging" -type l -delete
    find "$staging" -type d \( \
        -name node_modules -o -name .zag-cache -o -name .git -o \
        -name __pycache__ -o -name target \
    \) -prune -exec rm -rf -- {} +
    find "$staging" -type f \( \
        -name '*.zag.c' -o -name '*.zag.out' -o -name '*.zag.zir.c' -o \
        -name '*.o' \
    \) -delete
    forbidden=$(find "$staging" \( -type l -o -name node_modules -o -name .zag-cache \) -print -quit)
    [[ -z $forbidden ]] || die "forbidden path remains in staging: $forbidden"
    generate_source_manifest "$staging" "$staging/SOURCE_MANIFEST.sha256"
    normalize_staging_modes "$staging"

    (
        umask 022
        cd "$PACKAGE_TMP"
        LC_ALL=C tar --sort=name --mtime="@$source_date_epoch" \
            --owner=0 --group=0 --numeric-owner \
            --mode='u+rwX,go+rX,go-w' -cf - "$tarname" |
            gzip -n >"$archive"
    )
    (
        umask 022
        cd "$output_dir"
        sha256sum "$(basename "$archive")" >"$(basename "$checksum")"
    )
    verify_archive "$archive" "$checksum" "$tarname" "$arch" \
        "$release_commit" "$version"

    printf 'archive=%s\nchecksum=%s\n' "$archive" "$checksum"
}

release_source_preflight() {
    local version=$1
    [[ $EUID -ne 0 ]] ||
        die 'release builds must run as an ordinary user; use elevation only for make install-only.'
    [[ $version =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]+$ ]] ||
        die 'release version must be stable CalVer YYYY.MM.PATCH (no -dev suffix).'
    validate_versioned_source "$version"
    grep -Fq "## [$version]" CHANGELOG.md ||
        die "CHANGELOG.md has no release section for [$version]."
    git rev-parse --verify HEAD >/dev/null
    [[ -z $(git tag --list "v$version") ]] || die "tag v$version already exists."
    assert_clean_worktree
    [[ $(uname -s) == Linux ]] ||
        die "release packaging supports Linux hosts only, not $(uname -s)."
}

host_release_arch() {
    case $(uname -m) in
        x86_64|amd64) printf '%s\n' x86_64 ;;
        aarch64|arm64) printf '%s\n' aarch64 ;;
        *) die "release packaging is unsupported on host architecture $(uname -m)." ;;
    esac
}

build_vsix_isolated() {
    local editor_root
    command -v npm >/dev/null 2>&1 ||
        die 'npm is required to package the VS Code extension.'
    RELEASE_BUILD_TMP=$(mktemp -d "${TMPDIR:-/tmp}/zag-release-editor.XXXXXX")
    git -C .. archive --format=tar HEAD editors/vscode |
        tar -xf - -C "$RELEASE_BUILD_TMP"
    editor_root="$RELEASE_BUILD_TMP/editors/vscode"
    require_file "$editor_root/package-lock.json"
    require_file "$editor_root/THIRD_PARTY_NOTICES.md"
    (
        cd "$editor_root"
        npm ci
        npm run package
    )
    ISOLATED_VSIX="$editor_root/zag-lang.vsix"
    validate_vsix "$ISOLATED_VSIX"
}

build_host_candidate() {
    local version=$1 arch
    release_source_preflight "$version"
    arch=$(host_release_arch)

    echo '════════════════════════════════════════════════════════════════'
    echo "  Zag candidate: $version ($arch-linux; no tag)"
    echo '════════════════════════════════════════════════════════════════'
    echo '── canonical release gate ──'
    make --no-print-directory release-check
    echo '── unprivileged release-tool build ──'
    make --no-print-directory build-tools
    assert_clean_worktree

    echo '── isolated VS Code extension build ──'
    build_vsix_isolated
    echo '── reproducible candidate archive and staged-install verification ──'
    package_archive "$version" "$arch" "$PWD/dist" "$PWD" "$ISOLATED_VSIX"
    assert_clean_worktree

    echo '════════════════════════════════════════════════════════════════'
    echo "  Candidate ready; no tag was created."
    echo "  Transfer dist/zag-$version-$arch-linux.tar.gz and its .sha256 sidecar"
    echo '  to the finalizing checkout after the other architecture is built.'
    echo '════════════════════════════════════════════════════════════════'
}

absolute_archive_path() {
    local input=$1 directory basename
    require_file "$input"
    [[ ! -L $input ]] || die "release archive must not be a symlink: $input"
    directory=$(cd "$(dirname "$input")" && pwd -P)
    basename=$(basename "$input")
    printf '%s/%s\n' "$directory" "$basename"
}

verify_release_binaries_from_source() {
    local x86_root=$1 arm_root=$2 expected_root arch tool source
    local -a target_args=()
    expected_root="$PACKAGE_TMP/source-built-artifacts"
    for arch in x86_64 aarch64; do
        mkdir -p "$expected_root/$arch"
        if [[ $arch == aarch64 ]]; then target_args=(--target arm64); else target_args=(); fi
        for tool in znc zagd zag-lsp; do
            case $tool in
                znc) source=selfhost/native/znc.zag ;;
                zagd) source=selfhost/zagd_daemon.zag ;;
                zag-lsp) source=selfhost/lsp/zag-lsp.zag ;;
            esac
            ./znc "$source" "${target_args[@]}" -o "$expected_root/$arch/$tool" \
                --no-analyze --no-foreground-cache --no-zagd
        done
    done
    for tool in znc zagd zag-lsp; do
        cmp -s "$x86_root/$tool" "$expected_root/x86_64/$tool" ||
            die "x86-64 candidate $tool is not the deterministic source-built artifact"
        cmp -s "$arm_root/$tool" "$expected_root/aarch64/$tool" ||
            die "AArch64 candidate $tool is not the deterministic source-built artifact"
    done
}

finalize_release_pair() {
    local version=$1 x86_input=$2 arm_input=$3 mode=${4:-release}
    local x86_archive arm_archive x86_checksum arm_checksum commit
    local x86_name arm_name x86_hash arm_hash x86_verified_hash arm_verified_hash
    local x86_root arm_root

    case $mode in
        release)
            release_source_preflight "$version"
            [[ $(host_release_arch) == x86_64 ]] ||
                die 'signed finalization must run on the primary x86-64 seed host.'
            ;;
        dry-run)
            [[ $EUID -ne 0 ]] || die 'release verification must run as an ordinary user.'
            [[ $version =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]] ||
                die 'dry-run version must be a safe CalVer value.'
            validate_versioned_source "$version"
            git rev-parse --verify HEAD >/dev/null
            assert_clean_worktree
            [[ $(uname -s) == Linux ]] || die 'release verification requires Linux.'
            ;;
        *) die "invalid finalization mode: $mode" ;;
    esac
    x86_archive=$(absolute_archive_path "$x86_input")
    arm_archive=$(absolute_archive_path "$arm_input")
    x86_name="zag-$version-x86_64-linux.tar.gz"
    arm_name="zag-$version-aarch64-linux.tar.gz"
    [[ $(basename "$x86_archive") == "$x86_name" ]] ||
        die "x86-64 candidate must be named $x86_name"
    [[ $(basename "$arm_archive") == "$arm_name" ]] ||
        die "AArch64 candidate must be named $arm_name"
    x86_checksum="$x86_archive.sha256"
    arm_checksum="$arm_archive.sha256"
    require_file "$x86_checksum"
    require_file "$arm_checksum"
    commit=$(git rev-parse HEAD)

    PACKAGE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/zag-release-finalize.XXXXXX")
    echo '── verify x86-64 candidate against the final source commit ──'
    verify_archive "$x86_archive" "$x86_checksum" \
        "zag-$version-x86_64-linux" x86_64 "$commit" "$version"
    x86_root=$VERIFIED_ROOT
    x86_verified_hash=$VERIFIED_ARCHIVE_HASH
    echo '── verify AArch64 candidate against the final source commit ──'
    verify_archive "$arm_archive" "$arm_checksum" \
        "zag-$version-aarch64-linux" aarch64 "$commit" "$version"
    arm_root=$VERIFIED_ROOT
    arm_verified_hash=$VERIFIED_ARCHIVE_HASH

    cmp -s "$x86_root/SOURCE_MANIFEST.sha256" "$arm_root/SOURCE_MANIFEST.sha256" ||
        die 'x86-64 and AArch64 archives do not contain identical release source.'
    cmp -s "$x86_root/editors/vscode/zag-lang.vsix" \
        "$arm_root/editors/vscode/zag-lang.vsix" ||
        die 'x86-64 and AArch64 archives do not contain the same normalized VSIX.'

    x86_hash=$(sha256sum "$x86_archive" | awk '{ print $1 }')
    arm_hash=$(sha256sum "$arm_archive" | awk '{ print $1 }')
    [[ $x86_hash == "$x86_verified_hash" ]] ||
        die 'x86-64 candidate changed while the release pair was being verified.'
    [[ $arm_hash == "$arm_verified_hash" ]] ||
        die 'AArch64 candidate changed while the release pair was being verified.'

    if [[ $mode == dry-run ]]; then
        echo 'Pair validation dry-run passed: both candidates share one commit, source manifest, and VSIX.'
        echo 'The release gate, source rebuild, signed tag, and publication were deliberately not run.'
        return
    fi

    echo '── canonical release gate at the exact tag commit ──'
    make --no-print-directory release-check
    assert_clean_worktree
    echo '── deterministic source rebuild of all six release binaries ──'
    verify_release_binaries_from_source "$x86_root" "$arm_root"
    assert_clean_worktree

    x86_hash=$(sha256sum "$x86_archive" | awk '{ print $1 }')
    arm_hash=$(sha256sum "$arm_archive" | awk '{ print $1 }')
    [[ $x86_hash == "$x86_verified_hash" ]] ||
        die 'x86-64 candidate changed after verification; refusing to tag.'
    [[ $arm_hash == "$arm_verified_hash" ]] ||
        die 'AArch64 candidate changed after verification; refusing to tag.'
    TAG_MESSAGE_FILE="$PACKAGE_TMP/tag-message"
    printf 'Zag %s\n\nSource commit: %s\n\nArtifact: %s\nSHA-256: %s\n\nArtifact: %s\nSHA-256: %s\n' \
        "$version" "$commit" \
        "$x86_name" "$x86_hash" \
        "$arm_name" "$arm_hash" >"$TAG_MESSAGE_FILE"

    echo "── signed two-architecture tag v$version ──"
    git tag -s "v$version" -F "$TAG_MESSAGE_FILE"
    echo '════════════════════════════════════════════════════════════════'
    echo "  Release $version verified and signed as v$version"
    echo '  The signed tag binds the source commit and both archive hashes.'
    echo "  Verify with: git verify-tag v$version"
    echo "  Inspect with: git tag -l --format='%(contents)' v$version"
    echo "  Push with:   git push origin HEAD v$version"
    echo '════════════════════════════════════════════════════════════════'
}

if [[ ${1:-} == --package-only ]]; then
    [[ $# -eq 6 ]] || usage
    package_archive "$2" "$3" "$4" "$5" "$6"
    exit 0
fi

if [[ ${1:-} == --finalize ]]; then
    [[ $# -eq 4 ]] || usage
    finalize_release_pair "$2" "$3" "$4"
    exit 0
fi

if [[ ${1:-} == --finalize-dry-run ]]; then
    [[ $# -eq 4 ]] || usage
    finalize_release_pair "$2" "$3" "$4" dry-run
    exit 0
fi

[[ $# -eq 1 ]] || usage
build_host_candidate "$1"
