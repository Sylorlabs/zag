#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

ZNC_BIN=${ZNC:-./znc}
case "$ZNC_BIN" in
    /*) ;;
    *) ZNC_BIN="$PWD/${ZNC_BIN#./}" ;;
esac
command -v openssl >/dev/null 2>&1
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-package-signed-resolver.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

"$ZNC_BIN" tests/package_registry_signed_resolve.zag -o "$tmp/resolve" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/build.log" 2>&1
test -x "$tmp/resolve"

mkdir -p "$tmp/project/registry/src"
cat >"$tmp/project/zag.mod" <<'EOF'
name = "signed-registry-consumer"
version = "0.0.0"
edition = "2026"

[deps]
toolkit = { path = "registry/index.zag", mode = "registry", public_key = "registry/public.pem", signature = "registry/index.sig" }
EOF
printf 'pub fn answer() i32 { return 42; }\n' >"$tmp/project/registry/src/toolkit.zag"
raw_checksum() {
    od -An -tu1 -v "$1" | awk 'BEGIN{a=216613626;b=131542391;n=0}
    {for(i=1;i<=NF;i++){a=(a*257+$i+1)%1000000007;
    b=(b*263+$i+1)%1000000009;n++}}
    END{printf "%d,%d,%d",a,b,n}'
}
source_sum=$(raw_checksum "$tmp/project/registry/src/toolkit.zag")
cat >"$tmp/project/registry/index.body" <<'EOF'
format=zag-registry-index-v1
authority=local-file-v1
signature=ed25519
EOF
printf 'entry=toolkit\t1.0.0\tsrc/toolkit.zag\t%s\n' "$source_sum" >>"$tmp/project/registry/index.body"
registry_checksum() {
    od -An -tu1 -v "$1" | awk 'BEGIN{a=216613626;b=131542391;n=0}
    {for(i=1;i<=NF;i++){a=(a*257+$i+1)%1000000007;
    b=(b*263+$i+1)%1000000009;n++}}
    END{printf "checksum=%d,%d,%d\n",a,b,n}'
}
registry_checksum "$tmp/project/registry/index.body" \
    >>"$tmp/project/registry/index.body"
mv "$tmp/project/registry/index.body" "$tmp/project/registry/index.zag"
openssl genpkey -algorithm ED25519 -out "$tmp/project/registry/private.pem" >/dev/null 2>&1
openssl pkey -pubout -in "$tmp/project/registry/private.pem" \
    -out "$tmp/project/registry/public.pem" >/dev/null 2>&1
openssl pkeyutl -sign -inkey "$tmp/project/registry/private.pem" -rawin \
    -in "$tmp/project/registry/index.zag" \
    -out "$tmp/project/registry/index.sig" >/dev/null 2>&1

cp "$tmp/project/registry/index.zag" "$tmp/project/registry/index.original"
cp "$tmp/project/registry/index.sig" "$tmp/project/registry/index.sig.original"

expect_rejected() {
    local output=$1
    set +e
    "$tmp/resolve" "$tmp/project" >"$output"
    local rc=$?
    set -e
    test "$rc" -eq 1
    grep -qx 'signed resolver: rejected' "$output"
}

"$tmp/resolve" "$tmp/project" >"$tmp/verified.out"
grep -qx 'signed resolver: verified' "$tmp/verified.out"

openssl genpkey -algorithm ED25519 -out "$tmp/project/registry/wrong-private.pem" \
    >/dev/null 2>&1
openssl pkey -pubout -in "$tmp/project/registry/wrong-private.pem" \
    -out "$tmp/project/registry/wrong-public.pem" >/dev/null 2>&1
mv "$tmp/project/registry/public.pem" "$tmp/project/registry/public.good.pem"
cp "$tmp/project/registry/wrong-public.pem" "$tmp/project/registry/public.pem"
expect_rejected "$tmp/wrong-key.out"
rm -f "$tmp/project/registry/public.pem"
mv "$tmp/project/registry/public.good.pem" "$tmp/project/registry/public.pem"

mv "$tmp/project/registry/public.pem" "$tmp/project/registry/public.real.pem"
ln -s public.real.pem "$tmp/project/registry/public.pem"
expect_rejected "$tmp/symlink-key.out"
rm -f "$tmp/project/registry/public.pem"
mv "$tmp/project/registry/public.real.pem" "$tmp/project/registry/public.pem"

printf 'x' >>"$tmp/project/registry/index.zag"
expect_rejected "$tmp/rejected.out"

# Required per-artifact signatures are an explicit opt-in.  The fifth index
# field is optional for legacy v1 indexes, but required policy never silently
# falls back to checksum-only validation.
mkdir -p "$tmp/artifact/project/registry/src" "$tmp/artifact/project/registry/sig"
printf '%s\n' \
    'name = "artifact-signed-consumer"' \
    'version = "0.0.0"' \
    'edition = "2026"' \
    '' \
    '[deps]' \
    'toolkit = { path = "registry/index.zag", mode = "registry", public_key = "registry/public.pem", signature = "registry/index.sig", artifact_signatures = "required" }' \
    >"$tmp/artifact/project/zag.mod"
printf '%s\n' \
    '@import("pkg:toolkit/src/toolkit.zag") as toolkit' \
    'fn main() i32 { return toolkit.answer(); }' \
    >"$tmp/artifact/project/main.zag"
printf '%s\n' 'pub fn answer() i32 { return 42; }' \
    >"$tmp/artifact/project/registry/src/toolkit.zag"
openssl genpkey -algorithm ED25519 -out "$tmp/artifact/project/registry/private.pem" >/dev/null 2>&1
openssl pkey -pubout -in "$tmp/artifact/project/registry/private.pem" \
    -out "$tmp/artifact/project/registry/public.pem" >/dev/null 2>&1
artifact_sum=$(raw_checksum "$tmp/artifact/project/registry/src/toolkit.zag")
printf '%s\n' \
    'format=zag-registry-index-v1' \
    'authority=local-file-v1' \
    'signature=ed25519' \
    "entry=toolkit$(printf '\t')1.0.0$(printf '\t')src/toolkit.zag$(printf '\t')$artifact_sum$(printf '\t')sig/toolkit.sig" \
    >"$tmp/artifact/project/registry/index.body"
registry_checksum "$tmp/artifact/project/registry/index.body" \
    >>"$tmp/artifact/project/registry/index.body"
mv "$tmp/artifact/project/registry/index.body" \
    "$tmp/artifact/project/registry/index.zag"
openssl pkeyutl -sign -inkey "$tmp/artifact/project/registry/private.pem" -rawin \
    -in "$tmp/artifact/project/registry/src/toolkit.zag" \
    -out "$tmp/artifact/project/registry/sig/toolkit.sig" >/dev/null 2>&1
openssl pkeyutl -sign -inkey "$tmp/artifact/project/registry/private.pem" -rawin \
    -in "$tmp/artifact/project/registry/index.zag" \
    -out "$tmp/artifact/project/registry/index.sig" >/dev/null 2>&1
if ! (cd "$tmp/artifact/project" && "$ZNC_BIN" main.zag -o app \
    --no-zagd --no-analyze --no-foreground-cache >artifact-build.log 2>&1); then
    sed -n '1,100p' "$tmp/artifact/project/artifact-build.log" >&2
    exit 1
fi
test -x "$tmp/artifact/project/app"
set +e
"$tmp/artifact/project/app"
artifact_rc=$?
set -e
test "$artifact_rc" -eq 42

# Keep the index and checksum valid while signing different bytes.  Only the
# artifact verifier can reject this case.
printf '%s\n' 'pub fn answer() i32 { return 41; }' >"$tmp/artifact/wrong.zag"
openssl pkeyutl -sign -inkey "$tmp/artifact/project/registry/private.pem" -rawin \
    -in "$tmp/artifact/wrong.zag" \
    -out "$tmp/artifact/project/registry/sig/toolkit.sig" >/dev/null 2>&1
if (cd "$tmp/artifact/project" && "$ZNC_BIN" main.zag -o wrong-artifact \
    --no-zagd --no-analyze --no-foreground-cache >wrong-artifact.log 2>&1); then
    echo 'wrong artifact signature unexpectedly compiled' >&2
    exit 1
fi
test ! -e "$tmp/artifact/project/wrong-artifact"
grep -Fq 'signed registry index failed detached Ed25519 verification' \
    "$tmp/artifact/project/wrong-artifact.log"

# A required policy rejects a four-field entry, preserving compatibility for
# ordinary signed indexes while failing closed for explicit artifact policy.
openssl pkeyutl -sign -inkey "$tmp/artifact/project/registry/private.pem" -rawin \
    -in "$tmp/artifact/project/registry/src/toolkit.zag" \
    -out "$tmp/artifact/project/registry/sig/toolkit.sig" >/dev/null 2>&1
printf '%s\n' \
    'format=zag-registry-index-v1' \
    'authority=local-file-v1' \
    'signature=ed25519' \
    "entry=toolkit$(printf '\t')1.0.0$(printf '\t')src/toolkit.zag$(printf '\t')$artifact_sum" \
    >"$tmp/artifact/project/registry/index.body"
registry_checksum "$tmp/artifact/project/registry/index.body" \
    >>"$tmp/artifact/project/registry/index.body"
mv "$tmp/artifact/project/registry/index.body" \
    "$tmp/artifact/project/registry/index.zag"
openssl pkeyutl -sign -inkey "$tmp/artifact/project/registry/private.pem" -rawin \
    -in "$tmp/artifact/project/registry/index.zag" \
    -out "$tmp/artifact/project/registry/index.sig" >/dev/null 2>&1
if (cd "$tmp/artifact/project" && "$ZNC_BIN" main.zag -o missing-artifact \
    --no-zagd --no-analyze --no-foreground-cache >missing-artifact.log 2>&1); then
    echo 'missing required artifact signature unexpectedly compiled' >&2
    exit 1
fi
test ! -e "$tmp/artifact/project/missing-artifact"
grep -Fq 'signed registry index failed detached Ed25519 verification' \
    "$tmp/artifact/project/missing-artifact.log"

echo 'signed registry resolver: pass=6 fail=0'
