#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$root/tests/portable.sh"
compiler=${ZNC:-$root/znc}
case "$compiler" in /*) ;; *) compiler="$PWD/$compiler" ;; esac
work=$(mktemp -d "${TMPDIR:-/tmp}/zag-source-closure.XXXXXX")
work=$(CDPATH= cd -- "$work" && pwd -P)
trap 'rm -rf "$work"' EXIT
# Match the resolver layout for std: imports from a non-checkout CWD.
ln -s "$root/std" "$work/std"
ln -s "$root/selfhost" "$work/selfhost"
target=()
case "$(uname -s):$(uname -m)" in
    Darwin:arm64) target=(--target macos-arm64) ;;
    Linux:aarch64|Linux:arm64) target=(--target arm64) ;;
esac
"$compiler" "$root/selfhost/source_closure_test.zag" "${target[@]}" \
    --no-zagd --no-analyze --no-foreground-cache -o "$work/test" >"$work/build.log" 2>&1 || {
    cat "$work/build.log"; exit 1;
}
zag_assert_native_executable "$work/test"
# Pinned API fixture has no pkg: imports: the nested requirement must be
# discovered from the ordinary relative source edge, not a root-only precheck.
pin="sha256:$(zag_sha256_file "$compiler")"
mkdir -p "$work/pinned/nested" "$work/pinned/optional"
printf 'name = "pinned"\n[toolchain]\ncompiler = "%s"\n' "$pin" >"$work/pinned/zag.mod"
printf 'name = "nested"\n[toolchain]\ncompiler = "%s"\n' "$pin" >"$work/pinned/nested/zag.mod"
printf 'name = "optional"\n' >"$work/pinned/optional/zag.mod"
printf '@import("nested/helper.zag")\n@import("optional/helper.zag")\nfn main() i32 { return nested_value(); }\n' >"$work/pinned/main.zag"
printf 'pub fn nested_value() i32 { return 42; }\n' >"$work/pinned/nested/helper.zag"
printf 'pub fn optional_value() i32 { return 0; }\n' >"$work/pinned/optional/helper.zag"
(cd "$work" && "$work/test" --pinned-unit "$work/pinned/main.zag" "$work" "$pin")
mkdir "$work/project"
project="$work/project"
cat >"$project/zag.mod" <<'EOF'
name = "source-closure-test"
version = "0"
[toolchain]
compiler = "sha256:0000000000000000000000000000000000000000000000000000000000000000"
[deps]
kit = { path = "vendor/kit", mode = "vendor" }
EOF
cat >"$project/main.zag" <<'EOF'
@import("sha_helper.zag")
@import("diamond.zag")
@import("pkg:kit/src/kit.zag")
fn main() i32 {
    let payload: []u8 = #embed("payload.bin");
    let empty: []u8 = #embed("empty.bin");
    let opaque: []u8 = #embed("assets/zag.mod");
    return payload.len + empty.len + opaque.len;
}
EOF
# A real SHA helper with an IO dependency: manifest-only traversal cannot
# reveal io_helper.zag or the std:rt edge. Parsing doesn't execute file IO.
cat >"$project/sha_helper.zag" <<EOF
@import("$root/selfhost/native/macho_arm64.zag")
@import("io_helper.zag")
pub fn hash_file(path: []u8) ArrayList[u8] {
    let bytes: []u8 = closure_read_file(path);
    let digest: ArrayList[u8] = macho_sha256(bytes);
    _zag_free(_zag_slice_ptr(bytes));
    return digest;
}
EOF
cat >"$project/io_helper.zag" <<'EOF'
@import("std:rt")
pub fn closure_read_file(path: []u8) []u8 { return _zag_read_file(path); }
EOF
printf '@import("io_helper.zag")\n' >"$project/diamond.zag"
printf '\000\001\177\200\376\377A\nZ' >"$project/payload.bin"
: >"$project/empty.bin"
mkdir "$project/assets"
printf '\000arbitrary embedded data, not package metadata\377' >"$project/assets/zag.mod"
mkdir -p "$project/vendor/kit/src" "$project/vendor/leaf/src"
cat >"$project/vendor/kit/zag.mod" <<'EOF'
name = "kit"
[deps]
leaf = { path = "../leaf" }
[toolchain]
compiler = "sha256:1111111111111111111111111111111111111111111111111111111111111111"
EOF
printf 'name = "leaf"\n' >"$project/vendor/leaf/zag.mod"
printf '@import("pkg:leaf/src/leaf.zag")\npub fn kit_value() i32 { return leaf_value(); }\n' >"$project/vendor/kit/src/kit.zag"
printf 'pub fn leaf_value() i32 { return 42; }\n' >"$project/vendor/leaf/src/leaf.zag"
# The existing vendor lock format is a raw modular checksum. The closure must
# additionally bind the complete retained lock bytes with cryptographic SHA-256.
checksum=$(od -An -tu1 -v "$project/vendor/kit/src/kit.zag" |
    awk 'BEGIN { a=216613626; b=131542391; n=0 }
         { for(i=1;i<=NF;i++){a=(a*257+$i+1)%1000000007;b=(b*263+$i+1)%1000000009;n++} }
         END { printf "%.0f,%.0f,%d",a,b,n }')
printf 'format=zag-local-lock-v1\nentry=kit\tvendor/kit\tsrc/kit.zag\t%s\n' "$checksum" >"$project/zag.lock"

(cd "$work" && "$work/test" --unit "$project/main.zag" "$work")
(cd "$work" && "$work/test" --emit "$project/main.zag" "$work" "$work/first")
(cd "$project" && "$work/test" --emit ./main.zag "$project" "$work/second")
cmp "$work/first" "$work/second"
tab=$(printf '\t')
for name in main.zag sha_helper.zag io_helper.zag diamond.zag vendor/kit/src/kit.zag vendor/leaf/src/leaf.zag; do
    digest=$(zag_sha256_file "$project/$name")
    grep -Fq "source=$project/$name${tab}sha256:$digest${tab}" "$work/first"
    test "$(grep -Fc "source=$project/$name${tab}" "$work/first")" -eq 1
done
for name in payload.bin empty.bin assets/zag.mod zag.lock zag.mod vendor/kit/zag.mod; do
    digest=$(zag_sha256_file "$project/$name")
    grep -Fq "resource=$project/$name${tab}sha256:$digest${tab}" "$work/first"
done
for name in zag.mod vendor/kit/zag.mod vendor/leaf/zag.mod; do
    digest=$(zag_sha256_file "$project/$name")
    grep -Fq "manifest=$project/$name${tab}sha256:$digest${tab}" "$work/first"
done
grep -Fqx "pin=$project/zag.mod${tab}sha256:0000000000000000000000000000000000000000000000000000000000000000" "$work/first"
grep -Fqx "pin=$project/vendor/kit/zag.mod${tab}sha256:1111111111111111111111111111111111111111111111111111111111111111" "$work/first"
grep -Fqx "package=$project/zag.mod${tab}$project/vendor/kit/zag.mod${tab}kit${tab}vendor/kit${tab}vendor" "$work/first"
grep -Fqx "import=$project/sha_helper.zag${tab}$project/io_helper.zag${tab}io_helper.zag" "$work/first"
grep -Fqx "import=$project/io_helper.zag${tab}$work/std/rt.zag${tab}std:rt" "$work/first"
echo 'ok  cryptographic file hashes, nested edges, manifest pins, and CWD determinism'
printf '\n# manifest-only change\n' >>"$project/vendor/leaf/zag.mod"
(cd "$work" && "$work/test" --emit "$project/main.zag" "$work" "$work/manifest-changed")
if cmp -s "$work/first" "$work/manifest-changed"; then
    echo 'FAIL transitive manifest edit did not change closure' >&2; exit 1
fi
echo 'ok  transitive manifest bytes affect source closure'

reject() {
    local label=$1 expected=$2
    printf 'preserve previous output\n' >"$work/rejected"
    cp "$work/rejected" "$work/sentinel"
    if (cd "$root" && "$work/test" --emit "$project/main.zag" "$root" "$work/rejected") >"$work/reject.log" 2>&1; then
        echo "FAIL $label accepted" >&2; exit 1
    fi
    grep -Fq "$expected" "$work/reject.log" || { cat "$work/reject.log"; exit 1; }
    cmp "$work/rejected" "$work/sentinel"
    echo "ok  $label rejects before closure output"
}
mv "$project/io_helper.zag" "$work/io.saved"
reject 'missing nested IO import' '@import cannot read'
mv "$work/io.saved" "$project/io_helper.zag"
printf '@import("sha_helper.zag")\n' >>"$project/io_helper.zag"
reject 'nested source cycle' 'circular @import'
printf '@import("std:nonexistent_closure_fixture")\n' >"$project/io_helper.zag"
reject 'missing std import' '@import cannot read'
printf '@import("std:rt")\npub fn closure_read_file(path: []u8) []u8 { return _zag_read_file(path); }\n' >"$project/io_helper.zag"
mv "$project/payload.bin" "$work/payload.saved"
reject 'missing embedded resource' '#embed cannot read'
mv "$work/payload.saved" "$project/payload.bin"
mv "$project/main.zag" "$work/main.saved"
reject 'missing root source' 'cannot read source closure root'
mv "$work/main.saved" "$project/main.zag"
mv "$project/zag.lock" "$work/lock.saved"
reject 'missing vendor lock' 'vendor dependency requires canonical lockfile'
mv "$work/lock.saved" "$project/zag.lock"
mv "$project/vendor/leaf/zag.mod" "$work/leaf-mod.saved"
reject 'missing transitive manifest' 'invalid dependency manifest closure'
mv "$work/leaf-mod.saved" "$project/vendor/leaf/zag.mod"
echo 'Source closure: PASS'
