#!/usr/bin/env bash
# Run with ZNC=/absolute/path/to/a/current/compiler bash tests/run_native_evidence.sh.
set -euo pipefail
# Make the requested artifact mode observable independently of the caller's umask.
umask 022
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$root/tests/portable.sh"
compiler=${ZNC:-$root/znc}
case "$compiler" in /*) ;; *) compiler="$PWD/$compiler" ;; esac
test -x "$compiler" || { echo "missing compiler: $compiler" >&2; exit 1; }
work=$(mktemp -d "${TMPDIR:-/tmp}/zag-native-evidence.XXXXXX")
work=$(CDPATH= cd -- "$work" && pwd -P)
trap 'rm -rf "$work"' EXIT
case "$(zag_native_platform)" in
    macos-arm64) target=macos-arm64; receipt_target=macos-arm64 ;;
    linux-arm64) target=arm64; receipt_target=linux-arm64 ;;
    linux-x86_64) target=x86-64; receipt_target=linux-x86_64 ;;
    *) exit 1 ;;
esac
# All compiler working-directory state and generated fixtures stay in scratch.
ln -s "$root/std" "$work/std"
ln -s "$root/selfhost" "$work/selfhost"
cd "$work"
fail() { echo "FAIL native evidence: $*" >&2; exit 1; }
run_ok() {
    local log=$1; shift
    if ! "$@" >"$log" 2>&1; then cat "$log" >&2; fail "command failed: $*"; fi
}
reject() {
    local log=$1 diagnostic=$2 rc=0; shift 2
    "$@" >"$log" 2>&1 || rc=$?
    test "$rc" -eq 1 || { cat "$log" >&2; fail "expected refusal (1), got $rc: $*"; }
    grep -Fq -- "$diagnostic" "$log" || { cat "$log" >&2; fail "missing refusal diagnostic"; }
}
empty_store() {
    local dir=$1
    local entries=("$dir/store"/* "$dir/store"/.[!.]* "$dir/store"/..?*)
    test "${#entries[@]}" -eq 0 || fail "refusal populated content store"
}
no_evidence_outputs() {
    local dir=$1 file
    for file in "$dir/receipt.ev" "$dir/receipt.ev.inputs" "$dir/receipt.ev.provenance"; do
        test ! -e "$file" && test ! -L "$file" || fail "refusal published $file"
    done
    empty_store "$dir"
}
no_outputs() {
    local dir=$1
    test ! -e "$dir/program" && test ! -L "$dir/program" || fail "refusal published artifact"
    no_evidence_outputs "$dir"
}
only_log_and_store() {
    local dir=$1 file
    local entries=("$dir"/* "$dir"/.[!.]* "$dir"/..?*)
    for file in "${entries[@]}"; do
        case "$file" in "$dir/log"|"$dir/store") ;; *) fail "refusal created $file" ;; esac
    done
    no_outputs "$dir"
}
artifact_mode() {
    case "$target" in
        macos-arm64) stat -f '%Lp' "$1" ;;
        *) stat -c '%a' "$1" ;;
    esac
}
shopt -s nullglob

run_ok "$work/verifier-build.log" "$compiler" "$root/tests/native_evidence_verify.zag" \
    -o "$work/verify" --target "$target" --no-zagd --no-foreground-cache --no-analyze
zag_assert_native_executable "$work/verify"
# External SHA is only the independent test oracle. Production evidence is
# issued by the compiler and decoded/verified by the pure Zag executable below.
compiler_sha=$(zag_sha256_file "$compiler")
bad_pin=0000000000000000000000000000000000000000000000000000000000000000
test "$compiler_sha" != "$bad_pin" || fail 'bad-pin fixture matches compiler'
mkdir -p "$work/project/lib/nested" "$work/store"
project="$work/project"
cat >"$project/zag.mod" <<EOF
name = "native-evidence-test"
version = "0"
edition = "2026"
[toolchain]
compiler = "sha256:$compiler_sha"
EOF
cat >"$project/main.zag" <<'EOF'
@import("lib/answer.zag")
fn main() i32 { return answer() - 42; }
EOF
cat >"$project/lib/answer.zag" <<'EOF'
@import("nested/value.zag")
pub fn answer() i32 { return nested_value() + 2; }
EOF
printf 'pub fn nested_value() i32 { return 40; }\n' >"$project/lib/nested/value.zag"

run_ok "$work/closure.log" "$compiler" --emit-closure "$project/main.zag" -o "$work/closure"
run_ok "$work/closure.stdout" "$compiler" --emit-closure "$project/main.zag"
cmp "$work/closure" "$work/closure.stdout"
run_ok "$work/closure.source-first.stdout" "$compiler" "$project/main.zag" --emit-closure
cmp "$work/closure" "$work/closure.source-first.stdout"
run_ok "$work/closure.source-first.log" "$compiler" "$project/main.zag" --emit-closure -o "$work/closure.source-first"
cmp "$work/closure" "$work/closure.source-first"
grep -Fxq 'format=zag-source-closure-v1' "$work/closure"
tab=$(printf '\t')
for name in main.zag lib/answer.zag lib/nested/value.zag; do
    digest=$(zag_sha256_file "$project/$name")
    grep -Fq "source=$project/$name${tab}sha256:$digest${tab}" "$work/closure"
    test "$(grep -Fc "source=$project/$name${tab}" "$work/closure")" -eq 1
done
grep -Fxq "import=$project/main.zag${tab}$project/lib/answer.zag${tab}lib/answer.zag" "$work/closure"
grep -Fxq "import=$project/lib/answer.zag${tab}$project/lib/nested/value.zag${tab}nested/value.zag" "$work/closure"
digest=$(zag_sha256_file "$project/zag.mod")
grep -Fq "manifest=$project/zag.mod${tab}sha256:$digest${tab}" "$work/closure"
grep -Fxq "pin=$project/zag.mod${tab}sha256:$compiler_sha" "$work/closure"
echo 'ok  flag-first and source-first CLI closure agree on nested sources, edges, hashes and pin'

# Keep this argument order in sync with the verifier's exact invocation check.
build() {
    "$compiler" "$project/main.zag" -o "$work/program" \
        --build-receipt "$1" --compiler-pin "$compiler_sha" --content-store "$work/store" \
        --no-zagd --no-foreground-cache --no-analyze --target "$target"
}
run_ok "$work/build.log" build "$work/receipt.ev"
for file in program receipt.ev receipt.ev.inputs receipt.ev.provenance; do test -s "$work/$file"; done
zag_assert_native_executable "$work/program"
test "$(artifact_mode "$work/program")" = 755 || fail 'artifact mode is not 0755'
run_ok "$work/program.log" "$work/program"
artifact_sha=$(zag_sha256_file "$work/program")
receipt_sha=$(zag_sha256_file "$work/receipt.ev")
provenance_sha=$(zag_sha256_file "$work/receipt.ev.provenance")
cmp "$work/program" "$work/store/$artifact_sha"
grep -Fxq "znc evidence: receipt-sha256=$receipt_sha" "$work/build.log"
grep -Fxq "znc evidence: artifact-sha256=$artifact_sha" "$work/build.log"
verify() {
    "$work/verify" "$work" "$compiler" "$compiler_sha" "$receipt_sha" \
        "$provenance_sha" "$artifact_sha" "$receipt_target" "$1"
}
verify valid
echo 'ok  emitted program runs; actual compiler, artifact, receipt and synthetic provenance verify'

# Refuse an existing artifact even when every evidence output path is new.
mkdir -p "$work/existing-output/store"
cp "$work/program" "$work/existing-output/program"
cp "$work/existing-output/program" "$work/existing-output.saved"
mode_before=$(artifact_mode "$work/existing-output/program")
reject "$work/existing-output/log" 'artifact output must be new' "$compiler" "$project/main.zag" \
    -o "$work/existing-output/program" --build-receipt "$work/existing-output/receipt.ev" \
    --compiler-pin "$compiler_sha" --content-store "$work/existing-output/store" \
    --no-zagd --no-foreground-cache --no-analyze --target "$target"
cmp "$work/existing-output/program" "$work/existing-output.saved"
test "$(artifact_mode "$work/existing-output/program")" = "$mode_before"
no_evidence_outputs "$work/existing-output"
echo 'ok  existing artifact refused intact before evidence publication'

# Create-only publication must preserve all original receipt bytes on retry.
# Remove only the scratch artifact so these cases reach sidecar/receipt checks.
for suffix in '' .inputs .provenance; do cp "$work/receipt.ev$suffix" "$work/saved$suffix"; done
rm "$work/program"
reject "$work/duplicate.log" 'build is not receipted' build "$work/receipt.ev"
for suffix in '' .inputs .provenance; do cmp "$work/receipt.ev$suffix" "$work/saved$suffix"; done
verify valid
# An existing receipt alone must also refuse replacement. Its new sidecars may
# be published first: the receipt is the create-only completion marker.
cp "$work/receipt.ev" "$work/existing.ev"
rm "$work/program"
reject "$work/existing.log" 'build is not receipted' build "$work/existing.ev"
cmp "$work/existing.ev" "$work/saved"
echo 'ok  duplicate receipt refused without replacing evidence'

cp "$work/program" "$work/program.saved"
printf 'tampered artifact\n' >>"$work/program"
verify tampered-artifact
mv "$work/program.saved" "$work/program"
echo 'ok  on-disk artifact tampering rejected by receipt and provenance APIs'

printf 'wrong bytes under the correct artifact digest\n' >"$work/store/$artifact_sha"
cp "$work/store/$artifact_sha" "$work/store.sentinel"
verify mismatched-store
rm "$work/program"
reject "$work/store-mismatch.log" 'build is not receipted' build "$work/conflict.ev"
for suffix in '' .inputs .provenance; do test ! -e "$work/conflict.ev$suffix"; done
cmp "$work/store/$artifact_sha" "$work/store.sentinel"
test "$(zag_sha256_file "$work/program")" = "$artifact_sha"
echo 'ok  content-store identity mismatch refuses publication and preserves conflicting bytes'

mkdir -p "$work/bad-cli/store" "$work/bad-manifest/store"
reject "$work/bad-cli.log" 'compiler pin mismatch' "$compiler" "$project/main.zag" \
    -o "$work/bad-cli/program" --build-receipt "$work/bad-cli/receipt.ev" \
    --compiler-pin "$bad_pin" --content-store "$work/bad-cli/store" \
    --no-zagd --no-foreground-cache --no-analyze --target "$target"
no_outputs "$work/bad-cli"
mkdir -p "$work/duplicate-option/store"
reject "$work/duplicate-option.log" 'duplicate evidence build option' "$compiler" "$project/main.zag" \
    -o "$work/duplicate-option/program" --build-receipt "$work/duplicate-option/receipt.ev" \
    --build-receipt "$work/duplicate-option/second.ev" --compiler-pin "$compiler_sha" \
    --content-store "$work/duplicate-option/store" --no-zagd --no-foreground-cache --no-analyze
no_outputs "$work/duplicate-option"
for suffix in '' .inputs .provenance; do test ! -e "$work/duplicate-option/second.ev$suffix"; done
# Exercise the real driver, not the shell manifest identity helper.
cp "$project/zag.mod" "$work/manifest.saved"
printf 'name = "bad-pin"\n[toolchain]\ncompiler = "sha256:%s"\n' "$bad_pin" >"$project/zag.mod"
reject "$work/bad-manifest.log" 'toolchain identity mismatch' "$compiler" "$project/main.zag" \
    -o "$work/bad-manifest/program" --build-receipt "$work/bad-manifest/receipt.ev" \
    --compiler-pin "$compiler_sha" --content-store "$work/bad-manifest/store" \
    --no-zagd --no-foreground-cache --no-analyze --target "$target"
no_outputs "$work/bad-manifest"
mv "$work/manifest.saved" "$project/zag.mod"
echo 'ok  wrong CLI pin, duplicate receipt option and manifest toolchain pin fail before outputs'

# A paired value must not be reinterpreted as a global flag/subcommand. Run in
# an isolated CWD to catch accidental files named after the flag-shaped value.
for value in --emit-closure --target=wasm; do
    dir="$work/flag-value-${value#--}"
    mkdir -p "$dir/store"
    (
        cd "$dir"
        reject "$dir/log" 'flag-shaped evidence option value refused' "$compiler" "$project/main.zag" \
            -o "$dir/program" --build-receipt "$value" --compiler-pin "$compiler_sha" \
            --content-store "$dir/store" --no-zagd --no-foreground-cache --no-analyze --target "$target"
    )
    only_log_and_store "$dir"
done
echo 'ok  flag-shaped receipt values cannot dispatch closure or change target'

for command in init status watch; do
    dir="$work/non-build-$command"
    mkdir -p "$dir/store"
    (
        cd "$dir"
        reject "$dir/log" 'build receipts are only valid for native build commands' "$compiler" "$command" \
            -o "$dir/program" --build-receipt "$dir/receipt.ev" --compiler-pin "$compiler_sha" \
            --content-store "$dir/store" --no-zagd --no-foreground-cache --no-analyze
    )
    only_log_and_store "$dir"
done
echo 'ok  init/status/watch with evidence refused before command side effects'

# Check all three evidence output aliases, both literal and normalized paths;
# seed actual evidence bytes to prove refusal also preserves existing outputs.
for suffix in '' .inputs .provenance; do
    for spelling in literal normalized; do
        dir="$work/alias${suffix}-$spelling"
        mkdir -p "$dir/store" "$dir/nested"
        for saved_suffix in '' .inputs .provenance; do
            cp "$work/saved$saved_suffix" "$dir/receipt.ev$saved_suffix"
        done
        output="$dir/receipt.ev$suffix"
        if test "$spelling" = normalized; then output="$dir/nested/.././receipt.ev$suffix"; fi
        reject "$dir/log" 'artifact and evidence output paths conflict' "$compiler" "$project/main.zag" \
            -o "$output" --build-receipt "$dir/receipt.ev" --compiler-pin "$compiler_sha" \
            --content-store "$dir/store" --no-zagd --no-foreground-cache --no-analyze --target "$target"
        for saved_suffix in '' .inputs .provenance; do
            cmp "$dir/receipt.ev$saved_suffix" "$work/saved$saved_suffix"
        done
        empty_store "$dir"
    done
done
echo 'ok  artifact aliases of receipt, inputs and provenance refused before output'

# An existing inode reached through a hard/symbolic link must not be truncated
# or replaced. Use real receipt bytes as the protected target.
for kind in hard symlink; do
    dir="$work/existing-$kind"
    mkdir -p "$dir/store"
    cp "$work/receipt.ev" "$dir/protected.ev"
    if test "$kind" = hard; then ln "$dir/protected.ev" "$dir/program"
    else ln -s "$dir/protected.ev" "$dir/program"; fi
    mode_before=$(artifact_mode "$dir/protected.ev")
    reject "$dir/log" 'artifact output must be new' "$compiler" "$project/main.zag" \
        -o "$dir/program" --build-receipt "$dir/receipt.ev" --compiler-pin "$compiler_sha" \
        --content-store "$dir/store" --no-zagd --no-foreground-cache --no-analyze --target "$target"
    cmp "$dir/protected.ev" "$work/saved"
    cmp "$dir/program" "$work/saved"
    test "$dir/program" -ef "$dir/protected.ev" || fail "$kind artifact link was replaced"
    if test "$kind" = symlink; then test -L "$dir/program"; fi
    test "$(artifact_mode "$dir/protected.ev")" = "$mode_before"
    no_evidence_outputs "$dir"
done
echo 'ok  existing hard/symlink artifact targets and their links preserved'

for mode in --emit-obj --emit-static --dynamic --hot --emit-closure --script --debug; do
    dir="$work/rejected-${mode#--}"
    mkdir -p "$dir/store"
    reject "$dir/log" 'unsupported evidence build option' "$compiler" "$project/main.zag" \
        -o "$dir/program" --build-receipt "$dir/receipt.ev" --compiler-pin "$compiler_sha" \
        --content-store "$dir/store" --no-zagd --no-foreground-cache --no-analyze \
        --target "$target" "$mode"
    no_outputs "$dir"
done
echo 'ok  unsupported output modes fail before binary, receipt, sidecars or store output'
echo 'Native evidence: PASS'
