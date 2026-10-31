#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

ZNC_BIN=${ZNC:-./znc}
case "$ZNC_BIN" in
    /*) ;;
    *) ZNC_BIN="$PWD/${ZNC_BIN#./}" ;;
esac

command -v openssl >/dev/null 2>&1 || {
    echo 'package signature: openssl is required for the Linux host verifier' >&2
    exit 1
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-package-signature.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

"$ZNC_BIN" check selfhost/package_signature.zag --analyze-strict \
    --no-zagd --no-foreground-cache >"$tmp/check.log" 2>&1
grep -q 'znc: OK — all capability claims proven' "$tmp/check.log"

"$ZNC_BIN" tests/package_signature_verify.zag -o "$tmp/verify" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/build.log" 2>&1
test -x "$tmp/verify"

cat >"$tmp/index.body" <<'EOF'
format=zag-registry-index-v1
authority=local-file-v1
signature=ed25519
entry=toolkit	1.0.0	src/toolkit.zag	1,2,3
EOF
registry_checksum() {
    od -An -tu1 -v "$1" | awk 'BEGIN{a=216613626;b=131542391;n=0}
    {for(i=1;i<=NF;i++){a=(a*257+$i+1)%1000000007;
    b=(b*263+$i+1)%1000000009;n++}}
    END{printf "checksum=%d,%d,%d\n",a,b,n}'
}
registry_checksum "$tmp/index.body" >>"$tmp/index.body"
mv "$tmp/index.body" "$tmp/index.zag"

openssl genpkey -algorithm ED25519 -out "$tmp/private.pem" >/dev/null 2>&1
openssl pkey -pubout -in "$tmp/private.pem" -out "$tmp/public.pem" >/dev/null 2>&1
openssl pkeyutl -sign -inkey "$tmp/private.pem" -rawin \
    -in "$tmp/index.zag" -out "$tmp/signature.bin" >/dev/null 2>&1

run_expect() {
    expected="$1"; shift
    set +e
    "$tmp/verify" "$@" >"$tmp/run.out" 2>"$tmp/run.err"
    actual=$?
    set -e
    test "$actual" -eq "$expected"
}

run_expect 0 "$tmp/index.zag" "$tmp/public.pem" "$tmp/signature.bin"
grep -qx 'package signature: verified' "$tmp/run.out"

printf 'x' >>"$tmp/index.zag"
run_expect 1 "$tmp/index.zag" "$tmp/public.pem" "$tmp/signature.bin"
grep -qx 'package signature: rejected' "$tmp/run.out"

cp "$tmp/index.zag" "$tmp/index.bad"
sed -i '$d' "$tmp/index.bad"
registry_checksum "$tmp/index.bad" >>"$tmp/index.bad"
openssl genpkey -algorithm ED25519 -out "$tmp/wrong-private.pem" >/dev/null 2>&1
openssl pkey -pubout -in "$tmp/wrong-private.pem" -out "$tmp/wrong-public.pem" >/dev/null 2>&1
run_expect 1 "$tmp/index.bad" "$tmp/wrong-public.pem" "$tmp/signature.bin"

head -c 63 "$tmp/signature.bin" >"$tmp/short-signature.bin"
run_expect 1 "$tmp/index.bad" "$tmp/public.pem" "$tmp/short-signature.bin"

mkdir -p "$tmp/quote'path"
cp "$tmp/index.bad" "$tmp/quote'path/index.zag"
cp "$tmp/public.pem" "$tmp/quote'path/public.pem"
cp "$tmp/signature.bin" "$tmp/quote'path/signature.bin"
run_expect 1 "$tmp/quote'path/index.zag" "$tmp/quote'path/public.pem" \
    "$tmp/quote'path/signature.bin"

ln -s "$tmp/index.bad" "$tmp/index-link.zag"
run_expect 1 "$tmp/index-link.zag" "$tmp/public.pem" "$tmp/signature.bin"

echo 'package signature: pass=6 fail=0'
