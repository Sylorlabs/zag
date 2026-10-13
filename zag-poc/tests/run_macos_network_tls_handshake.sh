#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
. tests/portable.sh

if [ "$(uname -s):$(uname -m)" != Darwin:arm64 ]; then
    echo 'macOS Network TLS handshake requires native Apple Silicon' >&2
    exit 2
fi

compiler=${ZNC:-/var/folders/kf/5y26484x0571_3cq5b2hfk3w0000gn/T/zag-tls-gen2.MUDsCE/znc-gen2}
case "$compiler" in /*) ;; *) compiler="$PWD/$compiler" ;; esac
test -x "$compiler"

openssl_bin=${OPENSSL:-$(command -v openssl || true)}
if [ -z "$openssl_bin" ]; then
    echo 'macOS Network TLS handshake test tooling requires openssl' >&2
    exit 2
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/zag-network-tls-handshake.XXXXXX")
server_pid=
cleanup() {
    local rc=$?
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    if [ "$rc" -ne 0 ] || [ "${ZAG_TEST_KEEP_WORK:-0}" = 1 ]; then
        printf 'macOS Network TLS handshake: retained artifacts: %s\n' "$work" >&2
    else
        rm -rf "$work"
    fi
}
trap cleanup EXIT

port=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)

"$openssl_bin" req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
    -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost' \
    -addext 'extendedKeyUsage=serverAuth' \
    -keyout "$work/key.pem" -out "$work/cert.pem" \
    >"$work/cert.out" 2>"$work/cert.err"
"$openssl_bin" x509 -in "$work/cert.pem" -outform DER -out "$work/cert.der"

"$openssl_bin" s_server -quiet -accept "127.0.0.1:$port" \
    -cert "$work/cert.pem" -key "$work/key.pem" -tls1_3 \
    >"$work/server.out" 2>"$work/server.err" &
server_pid=$!

# Keep startup bounded and local. A plain TCP readiness connect is expected to
# produce one failed TLS attempt in the test server and leaves it listening.
python3 - "$port" <<'PY'
import socket, sys, time
port = int(sys.argv[1])
deadline = time.monotonic() + 5
while time.monotonic() < deadline:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=.2):
            raise SystemExit(0)
    except OSError:
        time.sleep(.05)
raise SystemExit("TLS test server did not become ready")
PY

build() {
    zag_run_bounded 240 "$compiler" \
        tests/fixtures/macos_network_tls_handshake/main.zag \
        --target macos-arm64 --dynamic -l dispatch \
        -framework Network -framework Security -framework CoreFoundation \
        --no-zagd --no-analyze --no-foreground-cache -o "$1"
}

build "$work/first"
build "$work/repeat"
cmp "$work/first" "$work/repeat"
file -b "$work/first" | grep -q 'Mach-O 64-bit executable arm64'
codesign --verify --deep --strict "$work/first"
otool -L "$work/first" >"$work/deps"
grep -Fq '/usr/lib/libSystem.B.dylib' "$work/deps"
grep -Fq '/usr/lib/system/libdispatch.dylib' "$work/deps"
grep -Fq '/System/Library/Frameworks/Network.framework/Versions/A/Network' "$work/deps"
grep -Fq '/System/Library/Frameworks/Security.framework/Versions/A/Security' "$work/deps"
grep -Fq '/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation' "$work/deps"
if grep -Eq 'libssl|libcrypto|Homebrew|/opt/' "$work/deps"; then
    echo 'macOS Network TLS handshake artifact picked up non-system TLS' >&2
    exit 1
fi

set +e
zag_run_bounded 15 "$work/first" "$port" "$work/cert.der" localhost 1
handshake_rc=$?
set -e
if [ "$handshake_rc" -ne 42 ]; then
    echo "macOS Network TLS verified handshake failed (exit=$handshake_rc)" >&2
    sed -n '1,40p' "$work/server.err" >&2 || true
    exit 1
fi

set +e
zag_run_bounded 15 "$work/first" "$port" "$work/cert.der" wrong.invalid 0
wrong_host_rc=$?
set -e
if [ "$wrong_host_rc" -ne 42 ]; then
    echo "macOS Network TLS wrong-host rejection failed (exit=$wrong_host_rc)" >&2
    sed -n '1,60p' "$work/server.err" >&2 || true
    exit 1
fi

echo 'macOS Network TLS handshake: PASS TLS1.3 + explicit trust anchor + hostname rejection'
