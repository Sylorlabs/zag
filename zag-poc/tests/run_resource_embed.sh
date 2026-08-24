#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
compiler="${ZNC:-./znc}"
case "$compiler" in /*) ;; *) compiler="$(pwd)/${compiler#./}" ;; esac
work="$(mktemp -d)"

cleanup() {
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "resource embedding gate failed; retained diagnostics:" >&2
        find "$work" -maxdepth 2 -type f -name '*.log' -print | sort |
        while IFS= read -r log; do
            echo "── ${log#$work/}" >&2
            sed -n '1,100p' "$log" >&2
        done
    fi
    trap - EXIT
    rm -rf -- "$work"
    exit "$rc"
}
trap cleanup EXIT

expect_exit() {
    expected=$1
    binary=$2
    runner=${3:-}
    set +e
    if [ -n "$runner" ]; then "$runner" "$binary"; else "$binary"; fi
    actual=$?
    set -e
    test "$actual" -eq "$expected"
}

expect_embed_error() {
    name=$1
    source=$2
    mkdir -p "$work/errors/$name"
    printf '%s\n' "$source" >"$work/errors/$name/main.zag"
    if "$compiler" "$work/errors/$name/main.zag" -o "$work/errors/$name/app" \
        --no-zagd --no-foreground-cache >"$work/errors/$name/compile.log" 2>&1; then
        echo "$name unexpectedly compiled" >&2
        return 1
    fi
    grep -q 'error\[E0017\]' "$work/errors/$name/compile.log"
    test ! -e "$work/errors/$name/app"
}

mkdir -p "$work/project/assets" "$work/project/lib"
printf '\000\001\177\200\376\377A\nZ' >"$work/project/assets/raw.bin"
: >"$work/project/assets/empty.bin"

cat >"$work/project/main.zag" <<'EOF'
fn main() i32 {
    let data: []u8 = #embed("assets/raw.bin");
    let empty: []u8 = #embed("assets/empty.bin");
    if (data.len != 9 || empty.len != 0) { return 1; }
    if (data[0] != 0 || data[1] != 1 || data[2] != 127) { return 2; }
    if (data[3] != 128 || data[4] != 254 || data[5] != 255) { return 3; }
    if (data[6] != 65 || data[7] != 10 || data[8] != 90) { return 4; }
    return 42;
}
EOF

"$compiler" "$work/project/main.zag" -o "$work/project/x86-a" \
    --no-zagd --no-foreground-cache >"$work/project/x86-a.log" 2>&1
"$compiler" "$work/project/main.zag" -o "$work/project/x86-b" \
    --no-zagd --no-foreground-cache >"$work/project/x86-b.log" 2>&1
expect_exit 42 "$work/project/x86-a"
cmp "$work/project/x86-a" "$work/project/x86-b"

cat >"$work/project/lib/check.zag" <<'EOF'
fn embedded_value() i32 {
    let data: []u8 = #embed("../assets/raw.bin");
    return (data[5] as i32) - 213;
}
EOF
cat >"$work/project/imported.zag" <<'EOF'
@import("lib/check.zag")
fn main() i32 { return embedded_value(); }
EOF
"$compiler" "$work/project/imported.zag" -o "$work/project/imported" \
    --no-zagd --no-foreground-cache >"$work/project/imported.log" 2>&1
expect_exit 42 "$work/project/imported"

if [ "$(uname -m)" = aarch64 ]; then
    arm_runner=""
else
    arm_runner="${QEMU:-qemu-aarch64-static}"
    command -v "$arm_runner" >/dev/null
fi
"$compiler" "$work/project/main.zag" --target arm64 -o "$work/project/arm64" \
    --no-zagd >"$work/project/arm64.log" 2>&1
file "$work/project/arm64" | grep -q 'ARM aarch64'
expect_exit 42 "$work/project/arm64" "$arm_runner"

# Formatting is source-only: it must preserve a resource expression even when
# the resource is unavailable in the formatter's current filesystem context.
printf 'fn main()i32{let b:[]u8=#embed("not-present.bin");return b.len;}\n' \
    >"$work/format.zag"
"$compiler" fmt "$work/format.zag" >"$work/formatted.zag" 2>"$work/format.log"
grep -q '#embed("not-present.bin")' "$work/formatted.zag"
! grep -q '???' "$work/formatted.zag"

expect_embed_error missing \
    'fn main() i32 { let b: []u8 = #embed("missing.bin"); return b.len; }'
expect_embed_error computed \
    'fn main() i32 { let b: []u8 = #embed(path); return b.len; }'
expect_embed_error extra-argument \
    'fn main() i32 { let b: []u8 = #embed("a", "b"); return b.len; }'
expect_embed_error empty \
    'fn main() i32 { let b: []u8 = #embed(""); return b.len; }'
expect_embed_error absolute \
    'fn main() i32 { let b: []u8 = #embed("/etc/hosts"); return b.len; }'
expect_embed_error unknown-directive \
    'fn main() i32 { let b: []u8 = #resource("a"); return b.len; }'

# Resource lookup is exact and source-relative. An import-style sibling lib/
# fallback would silently bind the wrong asset and must remain rejected.
mkdir -p "$work/search/app" "$work/search/lib"
printf 'wrong' >"$work/search/lib/ghost.bin"
printf 'fn main() i32 { let b: []u8 = #embed("ghost.bin"); return b.len; }\n' \
    >"$work/search/app/main.zag"
if "$compiler" "$work/search/app/main.zag" -o "$work/search/app/out" \
    --no-zagd --no-foreground-cache >"$work/search/app/compile.log" 2>&1; then
    echo 'resource lookup incorrectly used import fallback' >&2
    exit 1
fi
grep -q 'error\[E0017\]' "$work/search/app/compile.log"

# The foreground cache identity includes resource bytes, not only source tokens.
mkdir -p "$work/cache/assets"
printf 'name = "resource-cache"\nversion = "0"\nedition = "2026"\n' \
    >"$work/cache/zag.mod"
printf '*' >"$work/cache/assets/value.bin"
cat >"$work/cache/main.zag" <<'EOF'
fn main() i32 { let data: []u8 = #embed("assets/value.bin"); return data[0] as i32; }
EOF
(
    cd "$work/cache"
    "$compiler" main.zag -o cold --cache-report --no-zagd >cold.log
    grep -q 'znc cache: MISS stored machine code and data' cold.log
    expect_exit 42 ./cold
    "$compiler" main.zag -o warm --cache-report --no-zagd >warm.log
    grep -q 'znc cache: HIT revalidated machine code and data; codegen skipped' warm.log
    expect_exit 42 ./warm
    printf '+' >assets/value.bin
    "$compiler" main.zag -o changed --cache-report --no-zagd >changed.log
    grep -q 'znc cache: MISS stored machine code and data' changed.log
    expect_exit 43 ./changed
)

echo 'resource embedding conformance: PASS (x86-64, ARM64, parser, formatter, cache, determinism)'
