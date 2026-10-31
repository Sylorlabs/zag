#!/usr/bin/env bash
# Focused authority for the opt-in direct sibling package lock slice.
set -euo pipefail
cd "$(dirname "$0")/.."

ZNC_BIN=${ZNC:-./znc}
case "$ZNC_BIN" in
    /*) ;;
    *) ZNC_BIN="$PWD/${ZNC_BIN#./}" ;;
esac

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-package-sibling-lock.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fixture="$PWD/tests/package_resolution/workspace/sibling_consumer"
toolkit="$PWD/tests/package_resolution/workspace/toolkit"
nested_fixture="$PWD/tests/package_resolution/workspace/nested_sibling_consumer"
nested_toolkit="$PWD/tests/package_resolution/workspace/nested_toolkit"
nested_helper="$PWD/tests/package_resolution/workspace/nested_helper"
pass=0

ok() { printf 'ok  %s\n' "$1"; pass=$((pass + 1)); }

run_42() {
    local artifact=$1
    set +e
    "$artifact"
    local status=$?
    set -e
    test "$status" -eq 42
}

copy_project() {
    local name=$1
    if [ -e "$tmp/$name" ]; then rm -rf "$tmp/$name"; fi
    if [ -e "$tmp/toolkit" ]; then rm -rf "$tmp/toolkit"; fi
    cp -R "$fixture" "$tmp/$name"
    cp -R "$toolkit" "$tmp/toolkit"
}

copy_nested_project() {
    local name=$1
    if [ -e "$tmp/$name" ]; then rm -rf "$tmp/$name"; fi
    if [ -e "$tmp/nested_toolkit" ]; then rm -rf "$tmp/nested_toolkit"; fi
    if [ -e "$tmp/nested_helper" ]; then rm -rf "$tmp/nested_helper"; fi
    cp -R "$nested_fixture" "$tmp/$name"
    cp -R "$nested_toolkit" "$tmp/nested_toolkit"
    cp -R "$nested_helper" "$tmp/nested_helper"
}

copy_project positive
if "$ZNC_BIN" "$tmp/positive/src/main.zag" --no-zagd \
    --no-analyze --no-foreground-cache -o "$tmp/positive/app" \
    >"$tmp/positive/build.log" 2>&1 &&
    test -x "$tmp/positive/app" && run_42 "$tmp/positive/app"; then
    ok 'locked sibling direct entry compiles and runs'
else
    sed -n '1,80p' "$tmp/positive/build.log"
    exit 1
fi

if (cd "$tmp/positive" && "$ZNC_BIN" src/main.zag --no-zagd \
    --no-analyze --no-foreground-cache -o relative-app \
    >relative-build.log 2>&1) &&
    test -x "$tmp/positive/relative-app" &&
    run_42 "$tmp/positive/relative-app" &&
    cmp -s "$tmp/positive/app" "$tmp/positive/relative-app"; then
    ok 'locked sibling entry is relocation/CWD deterministic'
else
    sed -n '1,80p' "$tmp/positive/relative-build.log"
    exit 1
fi

copy_project relocated
if "$ZNC_BIN" "$tmp/relocated/src/main.zag" --no-zagd \
    --no-analyze --no-foreground-cache -o "$tmp/relocated/app" \
    >"$tmp/relocated/build.log" 2>&1 &&
    test -x "$tmp/relocated/app" && run_42 "$tmp/relocated/app" &&
    cmp -s "$tmp/positive/app" "$tmp/relocated/app"; then
    ok 'locked sibling entry is checkout-relocation deterministic'
else
    sed -n '1,80p' "$tmp/relocated/build.log"
    exit 1
fi

copy_project generator
rm "$tmp/generator/zag.lock"
if (cd "$tmp/generator" && "$ZNC_BIN" package lock src/main.zag \
    --no-zagd --no-analyze --no-foreground-cache >generator.log 2>&1) &&
    cmp -s "$tmp/generator/zag.lock" "$fixture/zag.lock"; then
    ok 'create-only generator emits the exact sibling-root lock tuple'
else
    sed -n '1,80p' "$tmp/generator/generator.log"
    exit 1
fi

copy_project missing-lock
rm "$tmp/missing-lock/zag.lock"
if "$ZNC_BIN" "$tmp/missing-lock/src/main.zag" --no-zagd \
    --no-analyze --no-foreground-cache -o "$tmp/missing-lock/app" \
    >"$tmp/missing-lock/build.log" 2>&1; then
    echo 'missing sibling lock unexpectedly compiled' >&2
    exit 1
elif grep -Fq 'sibling dependency requires canonical lockfile' \
    "$tmp/missing-lock/build.log" && [ ! -e "$tmp/missing-lock/app" ]; then
    ok 'missing sibling lock fails before artifact publication'
else
    sed -n '1,80p' "$tmp/missing-lock/build.log"
    exit 1
fi

copy_project stale
printf '%s\n' '// sibling raw-byte mutation' >>"$tmp/toolkit/src/toolkit.zag"
if "$ZNC_BIN" "$tmp/stale/src/main.zag" --no-zagd \
    --no-analyze --no-foreground-cache -o "$tmp/stale/app" \
    >"$tmp/stale/build.log" 2>&1; then
    echo 'stale sibling module unexpectedly compiled' >&2
    exit 1
elif grep -Fq 'sibling module raw checksum mismatch' "$tmp/stale/build.log" &&
    [ ! -e "$tmp/stale/app" ]; then
    ok 'mutated sibling module fails checksum validation'
else
    sed -n '1,80p' "$tmp/stale/build.log"
    exit 1
fi

copy_project malformed
printf '%s\n' 'future=unsupported' >>"$tmp/malformed/zag.lock"
if "$ZNC_BIN" "$tmp/malformed/src/main.zag" --no-zagd \
    --no-analyze --no-foreground-cache -o "$tmp/malformed/app" \
    >"$tmp/malformed/build.log" 2>&1; then
    echo 'malformed sibling lock unexpectedly compiled' >&2
    exit 1
elif grep -Fq 'invalid canonical sibling lockfile' "$tmp/malformed/build.log" &&
    [ ! -e "$tmp/malformed/app" ]; then
    ok 'malformed sibling lock fails closed'
else
    sed -n '1,80p' "$tmp/malformed/build.log"
    exit 1
fi

copy_project symlink
mv "$tmp/toolkit/src/toolkit.zag" "$tmp/toolkit/src/toolkit.real"
ln -s toolkit.real "$tmp/toolkit/src/toolkit.zag"
if "$ZNC_BIN" "$tmp/symlink/src/main.zag" --no-zagd \
    --no-analyze --no-foreground-cache -o "$tmp/symlink/app" \
    >"$tmp/symlink/build.log" 2>&1; then
    echo 'symlinked sibling module unexpectedly compiled' >&2
    exit 1
elif grep -Fq 'locked package path contains a symlink' "$tmp/symlink/build.log" &&
    [ ! -e "$tmp/symlink/app" ]; then
    ok 'symlinked sibling module fails no-follow validation'
else
    sed -n '1,80p' "$tmp/symlink/build.log"
    exit 1
fi

copy_project intermediate-symlink
mv "$tmp/toolkit/src" "$tmp/toolkit/src.real"
ln -s src.real "$tmp/toolkit/src"
if "$ZNC_BIN" "$tmp/intermediate-symlink/src/main.zag" --no-zagd \
    --no-analyze --no-foreground-cache -o "$tmp/intermediate-symlink/app" \
    >"$tmp/intermediate-symlink/build.log" 2>&1; then
    echo 'intermediate-symlinked sibling path unexpectedly compiled' >&2
    exit 1
elif grep -Fq 'locked package path contains a symlink' \
    "$tmp/intermediate-symlink/build.log" &&
    [ ! -e "$tmp/intermediate-symlink/app" ]; then
    ok 'intermediate symlink in sibling path fails no-follow validation'
else
    sed -n '1,80p' "$tmp/intermediate-symlink/build.log"
    exit 1
fi

copy_project invalid-root
sed -i 's#path = "../toolkit"#path = "../../toolkit"#' \
    "$tmp/invalid-root/zag.mod"
if "$ZNC_BIN" "$tmp/invalid-root/src/main.zag" --no-zagd \
    --no-analyze --no-foreground-cache -o "$tmp/invalid-root/app" \
    >"$tmp/invalid-root/build.log" 2>&1; then
    echo 'nested sibling root unexpectedly compiled' >&2
    exit 1
elif { grep -Fq 'dependency path must be relative and use' \
        "$tmp/invalid-root/build.log" ||
       grep -Fq 'invalid or missing path entry for dependency' \
        "$tmp/invalid-root/build.log"; } &&
    [ ! -e "$tmp/invalid-root/app" ]; then
    ok 'nested sibling root fails closed before filesystem resolution'
else
    sed -n '1,80p' "$tmp/invalid-root/build.log"
    exit 1
fi

# A nested sibling package owns its own manifest and lock. The root lock pins
# the direct toolkit entry; the toolkit lock pins its helper entry. Keeping
# lock scope with the owning manifest avoids interpreting a relative helper
# root against the consumer's directory.
copy_nested_project nested-positive
if "$ZNC_BIN" "$tmp/nested-positive/src/main.zag" --no-zagd \
    --no-analyze --no-foreground-cache -o "$tmp/nested-positive/app" \
    >"$tmp/nested-positive/build.log" 2>&1 &&
    test -x "$tmp/nested-positive/app" &&
    run_42 "$tmp/nested-positive/app"; then
    ok 'nested sibling lock chain compiles and runs'
else
    sed -n '1,100p' "$tmp/nested-positive/build.log"
    exit 1
fi

copy_nested_project nested-relocated
if "$ZNC_BIN" "$tmp/nested-relocated/src/main.zag" --no-zagd \
    --no-analyze --no-foreground-cache -o "$tmp/nested-relocated/app" \
    >"$tmp/nested-relocated/build.log" 2>&1 &&
    test -x "$tmp/nested-relocated/app" &&
    run_42 "$tmp/nested-relocated/app" &&
    cmp -s "$tmp/nested-positive/app" "$tmp/nested-relocated/app"; then
    ok 'nested sibling lock chain is relocation deterministic'
else
    sed -n '1,100p' "$tmp/nested-relocated/build.log"
    exit 1
fi

copy_nested_project nested-generator
if (cd "$tmp/nested_toolkit" && "$ZNC_BIN" package lock src/toolkit.zag \
    --output "$tmp/nested-helper.lock" --no-zagd --no-analyze \
    --no-foreground-cache >nested-generator.log 2>&1) &&
    cmp -s "$tmp/nested-helper.lock" "$nested_toolkit/zag.lock"; then
    ok 'nested package generator emits the helper-owned lock'
else
    sed -n '1,100p' "$tmp/nested_toolkit/nested-generator.log"
    exit 1
fi

copy_nested_project nested-missing-lock
rm "$tmp/nested_toolkit/zag.lock"
if "$ZNC_BIN" "$tmp/nested-missing-lock/src/main.zag" --no-zagd \
    --no-analyze --no-foreground-cache -o "$tmp/nested-missing-lock/app" \
    >"$tmp/nested-missing-lock/build.log" 2>&1; then
    echo 'missing nested sibling lock unexpectedly compiled' >&2
    exit 1
elif grep -Eiq 'lockfile|zag\.lock' "$tmp/nested-missing-lock/build.log" &&
    [ ! -e "$tmp/nested-missing-lock/app" ]; then
    ok 'missing nested sibling lock fails before publication'
else
    sed -n '1,100p' "$tmp/nested-missing-lock/build.log"
    exit 1
fi

copy_nested_project nested-stale
printf '%s\n' '// nested helper raw-byte mutation' \
    >>"$tmp/nested_helper/src/helper.zag"
if "$ZNC_BIN" "$tmp/nested-stale/src/main.zag" --no-zagd \
    --no-analyze --no-foreground-cache -o "$tmp/nested-stale/app" \
    >"$tmp/nested-stale/build.log" 2>&1; then
    echo 'stale nested sibling module unexpectedly compiled' >&2
    exit 1
elif grep -Fq 'sibling module raw checksum mismatch' \
    "$tmp/nested-stale/build.log" &&
    [ ! -e "$tmp/nested-stale/app" ]; then
    ok 'mutated nested sibling module fails its owning lock'
else
    sed -n '1,100p' "$tmp/nested-stale/build.log"
    exit 1
fi

copy_project cache
if "$ZNC_BIN" "$tmp/cache/src/main.zag" --no-zagd --cache-report \
    --no-analyze -o "$tmp/cache/first" >"$tmp/cache/first.log" 2>&1 &&
    "$ZNC_BIN" "$tmp/cache/src/main.zag" --no-zagd --cache-report \
    --no-analyze -o "$tmp/cache/second" >"$tmp/cache/second.log" 2>&1 &&
    test -x "$tmp/cache/first" && test -x "$tmp/cache/second" &&
    run_42 "$tmp/cache/first" && run_42 "$tmp/cache/second" &&
    cmp -s "$tmp/cache/first" "$tmp/cache/second" &&
    grep -Fq 'znc cache: HIT' "$tmp/cache/second.log"; then
    printf '%s\n' '// cache-visible sibling mutation' >>"$tmp/toolkit/src/toolkit.zag"
    if "$ZNC_BIN" "$tmp/cache/src/main.zag" --no-zagd --cache-report \
        --no-analyze -o "$tmp/cache/after-mutation" \
        >"$tmp/cache/after-mutation.log" 2>&1; then
        echo 'cached sibling mutation unexpectedly compiled' >&2
        exit 1
    fi
    if grep -Fq 'sibling module raw checksum mismatch' \
        "$tmp/cache/after-mutation.log" &&
        [ ! -e "$tmp/cache/after-mutation" ]; then
        ok 'cache hit cannot bypass sibling lock revalidation'
    else
        sed -n '1,80p' "$tmp/cache/after-mutation.log"
        exit 1
    fi
else
    sed -n '1,80p' "$tmp/cache/first.log"
    sed -n '1,80p' "$tmp/cache/second.log"
    exit 1
fi

if command -v strace >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1 &&
    timeout 5 strace -qq -e trace=none -o "$tmp/trace-probe" /bin/true \
    >/dev/null 2>&1; then
    copy_project network
    if strace -f -qq -e trace=network -o "$tmp/network.trace" \
        "$ZNC_BIN" "$tmp/network/src/main.zag" --no-zagd \
        --no-analyze --no-foreground-cache -o "$tmp/network/app" \
        >"$tmp/network/build.log" 2>&1 &&
        [ ! -s "$tmp/network.trace" ] && test -x "$tmp/network/app" &&
        run_42 "$tmp/network/app"; then
        ok 'sibling lock resolution performs zero traced network syscalls'
    else
        sed -n '1,80p' "$tmp/network/build.log"
        cat "$tmp/network.trace"
        exit 1
    fi
else
    printf 'SKIP network trace unavailable in portable focused mode (not a pass)\n'
fi

printf 'Package sibling lock: pass=%s fail=0\n' "$pass"
