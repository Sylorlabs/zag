#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

ZNC_BIN=${ZNC:-./znc}
case "$ZNC_BIN" in
    /*) ;;
    *) ZNC_BIN="$PWD/${ZNC_BIN#./}" ;;
esac

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-package-registry-lock-resolve.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

# Match the compiler's bounded raw-byte checksum for the cache-provenance
# mutation below. Registry/index/lock fixtures are ASCII, so od's byte stream
# is sufficient and avoids depending on a host digest implementation.
raw_checksum() {
    local file=$1
    local a=216613626
    local b=131542391
    local byte
    local -a bytes
    while read -r -a bytes; do
        for byte in "${bytes[@]}"; do
            a=$(( (a * 257 + byte + 1) % 1000000007 ))
            b=$(( (b * 263 + byte + 1) % 1000000009 ))
        done
    done < <(od -An -tu1 -v "$file")
    printf '%s,%s,%s\n' "$a" "$b" "$(stat -c '%s' "$file")"
}

write_explicit_registry_lock() {
    local extra=$1
    local body="$tmp/workspace/registry.lock.body"
    local index_sum
    local artifact_sum
    local lock_sum
    index_sum=$(raw_checksum "$tmp/workspace/registry/index.zag")
    artifact_sum=$(raw_checksum "$tmp/workspace/registry/src/toolkit.zag")
    printf 'format=zag-registry-lock-v1\n' >"$body"
    printf 'entry=toolkit\tregistry/index.zag\t%s\t1.0.0\tsrc/toolkit.zag\t%s\tsig/toolkit.sig\n' \
        "$index_sum" "$artifact_sum" >>"$body"
    if [ "$extra" -eq 1 ]; then
        printf 'entry=zz-extra\tregistry/index.zag\t%s\t1.0.0\tsrc/toolkit.zag\t%s\tsig/toolkit.sig\n' \
            "$index_sum" "$artifact_sum" >>"$body"
    fi
    lock_sum=$(raw_checksum "$body")
    cp "$body" "$tmp/workspace/registry.lock"
    printf 'checksum=%s\n' "$lock_sum" >>"$tmp/workspace/registry.lock"
}

# This fixture exercises the production resolver's explicit opt-in lock path,
# not the older validation-only codec. Keep the compiler source authority
# check separate so a stale artifact cannot make the resolver test green.
"$ZNC_BIN" check selfhost/package_resolve.zag --analyze-strict \
    --no-zagd --no-foreground-cache >"$tmp/check.log" 2>&1
grep -q 'znc: OK — all capability claims proven' "$tmp/check.log"

"$ZNC_BIN" tests/package_registry_lock_resolve.zag -o "$tmp/test" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/build.log" 2>&1
test -x "$tmp/test"

mkdir -p "$tmp/workspace/registry/src" "$tmp/workspace/src" \
    "$tmp/workspace/nested/src" "$tmp/workspace/nested/registry/src"
"$tmp/test" "$tmp/workspace" >"$tmp/out"
grep -qx 'package registry lock resolver: 18/18' "$tmp/out"

# The direct resolver assertions above are followed by a real parser/import
# path compile. The fixture intentionally omits `registry_lock` from the root
# manifest, so this confirms default @import admission discovers and consumes
# the conventional graph-lock sidecar before producing an executable.
cat >"$tmp/workspace/src/main.zag" <<'ZAG'
@import("pkg:toolkit/src/toolkit.zag") as toolkit
fn main() i32 { return toolkit.answer(); }
ZAG
if ! "$ZNC_BIN" "$tmp/workspace/src/main.zag" -o "$tmp/workspace/app" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/e2e.log" 2>&1; then
    cat "$tmp/e2e.log" >&2
    od -An -tc "$tmp/workspace/registry.lock" >&2
    exit 1
fi
test -x "$tmp/workspace/app"
test -f "$tmp/workspace/.zag-cache/zagd/semantic.record"
if ! grep -q $'^dependency_input_node=.*registry.lock\t' \
    "$tmp/workspace/.zag-cache/zagd/semantic.record"; then
    echo 'validated registry.lock sidecar was not retained in semantic resources' >&2
    grep 'dependency_input_node=' "$tmp/workspace/.zag-cache/zagd/semantic.record" >&2 || true
    exit 1
fi

# A valid, unrelated v1 lock entry changes only lock provenance. The native
# program must remain byte-identical, while the semantic record must change;
# this proves registry.lock is a real freshness input rather than a discarded
# resolver witness. v1 is used here intentionally so parser graph-edge
# coverage remains independent of this resource-invalidation check.
printf 'name = "registry-lock-consumer"\nversion = "0.0.0"\nedition = "2026"\n\n[deps]\ntoolkit = { path = "registry/index.zag", mode = "registry", version = "^1.0.0", registry_lock = "registry.lock" }\n' \
    >"$tmp/workspace/zag.mod"
write_explicit_registry_lock 0
if ! "$ZNC_BIN" "$tmp/workspace/src/main.zag" -o "$tmp/workspace/app-v1" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/v1-first.log" 2>&1; then
    cat "$tmp/v1-first.log" >&2
    exit 1
fi
test -x "$tmp/workspace/app-v1"
v1_binary_before=$(sha256sum "$tmp/workspace/app-v1" | awk '{print $1}')
v1_semantic_before=$(sha256sum "$tmp/workspace/.zag-cache/zagd/semantic.record" | awk '{print $1}')
write_explicit_registry_lock 1
if ! "$ZNC_BIN" "$tmp/workspace/src/main.zag" -o "$tmp/workspace/app-v1-extra" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/v1-second.log" 2>&1; then
    cat "$tmp/v1-second.log" >&2
    exit 1
fi
test -x "$tmp/workspace/app-v1-extra"
v1_binary_after=$(sha256sum "$tmp/workspace/app-v1-extra" | awk '{print $1}')
v1_semantic_after=$(sha256sum "$tmp/workspace/.zag-cache/zagd/semantic.record" | awk '{print $1}')
if [ "$v1_binary_before" != "$v1_binary_after" ] ||
    [ "$v1_semantic_before" = "$v1_semantic_after" ]; then
    echo 'valid registry.lock mutation did not preserve code bytes and invalidate semantic identity' >&2
    exit 1
fi
grep -q $'^dependency_input_node=.*registry.lock\t' \
    "$tmp/workspace/.zag-cache/zagd/semantic.record"
set +e
"$tmp/workspace/app" >"$tmp/app.out" 2>&1
app_rc=$?
set -e
test "$app_rc" -eq 42

echo 'package registry lock resolver: pass=18 fail=0 (explicit and conventional registry-lock paths)'
