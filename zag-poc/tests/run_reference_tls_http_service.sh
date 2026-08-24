#!/usr/bin/env bash
# Bounded OpenSSL 3 TLS 1.3 HTTP client/server reference gate.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${ZNC:-"$root/znc"}
case "$compiler" in
    /*) ;;
    *) compiler="$root/${compiler#./}" ;;
esac
tmp=$(mktemp -d /tmp/zag-reference-tls-http.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
source_file="$root/tests/reference_apps/tls_http_service/main.zag"
pass=0
expected_pass=11

if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
    echo 'TLS HTTP reference app: unsupported host (requires Linux x86-64)' >&2
    exit 2
fi
if ! command -v openssl >/dev/null 2>&1 ||
   ! grep -q 'libssl\.so\.3' < <(ldconfig -p 2>/dev/null) ||
   ! grep -q 'libcrypto\.so\.3' < <(ldconfig -p 2>/dev/null); then
    echo 'TLS HTTP reference app: OpenSSL 3 runtime/tooling unavailable' >&2
    exit 2
fi

openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
    -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost' \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" \
    >"$tmp/cert.out" 2>"$tmp/cert.err"
openssl x509 -in "$tmp/cert.pem" -noout -checkhost localhost | \
    grep -q 'does match certificate'
pass=$((pass + 1))

build_one() {
    local output=$1
    timeout 300 "$compiler" "$source_file" --dynamic \
        --needed libssl.so.3 --needed libcrypto.so.3 \
        --no-zagd --no-analyze --no-foreground-cache -o "$output" \
        >"$output.build.out" 2>"$output.build.err"
    test -x "$output"
}

assert_tls_dynamic_elf() {
    local artifact=$1
    test -x "$artifact"
    readelf -h "$artifact" | grep -Eq 'Class:[[:space:]]+ELF64'
    readelf -h "$artifact" | grep -Eq 'Type:[[:space:]]+EXEC'
    readelf -h "$artifact" | \
        grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64'
    readelf -l "$artifact" | grep -q 'INTERP'
    test "$(readelf -d "$artifact" | grep -c 'NEEDED')" -eq 2
    readelf -d "$artifact" | grep -Eq \
        'NEEDED.*Shared library: \[libssl\.so\.3\]'
    readelf -d "$artifact" | grep -Eq \
        'NEEDED.*Shared library: \[libcrypto\.so\.3\]'
    ldd "$artifact" | grep -q 'libssl\.so\.3 => /'
    ldd "$artifact" | grep -q 'libcrypto\.so\.3 => /'
}

run_tls_service() {
    local artifact=$1
    local label=$2
    timeout 30 "$artifact" "$tmp/cert.pem" "$tmp/key.pem" \
        >"$tmp/$label.out" 2>"$tmp/$label.err"
    printf 'tls http service: protocol=TLSv1.3 status=200 body=42 negatives=4\n' | \
        cmp -s - "$tmp/$label.out"
    test ! -s "$tmp/$label.err"
}

build_one "$tmp/tls-http-a"
pass=$((pass + 1))
build_one "$tmp/tls-http-b"
pass=$((pass + 1))
cmp -s "$tmp/tls-http-a" "$tmp/tls-http-b"
pass=$((pass + 1))
assert_tls_dynamic_elf "$tmp/tls-http-a"
pass=$((pass + 1))
assert_tls_dynamic_elf "$tmp/tls-http-b"
pass=$((pass + 1))
run_tls_service "$tmp/tls-http-a" app
pass=$((pass + 1))
run_tls_service "$tmp/tls-http-b" app-repro
pass=$((pass + 1))

timeout 30 "$tmp/tls-http-a" "$tmp/cert.pem" "$tmp/key.pem" \
    --expect-hostname-failure >"$tmp/wrong-host.out" 2>"$tmp/wrong-host.err"
test ! -s "$tmp/wrong-host.out"
test ! -s "$tmp/wrong-host.err"
pass=$((pass + 1))

rm -f "$tmp/no-dynamic"
if "$compiler" "$source_file" --needed libssl.so.3 \
    --needed libcrypto.so.3 --no-zagd --no-analyze --no-foreground-cache \
    -o "$tmp/no-dynamic" >"$tmp/no-dynamic.log" 2>&1; then
    echo 'TLS HTTP reference app compiled without explicit dynamic mode' >&2
    exit 1
fi
grep -q 'requires explicit --dynamic mode' "$tmp/no-dynamic.log"
test ! -e "$tmp/no-dynamic"
pass=$((pass + 1))

rm -f "$tmp/no-soname"
if "$compiler" "$source_file" --dynamic \
    --no-zagd --no-analyze --no-foreground-cache -o "$tmp/no-soname" \
    >"$tmp/no-soname.log" 2>&1; then
    echo 'TLS HTTP reference app compiled without explicit TLS SONAMEs' >&2
    exit 1
fi
grep -q 'dynamic requires at least one --needed SONAME' "$tmp/no-soname.log"
test ! -e "$tmp/no-soname"
pass=$((pass + 1))

test "$pass" -eq "$expected_pass"
printf 'TLS HTTP reference app: pass=%d fail=0\n' "$pass"
