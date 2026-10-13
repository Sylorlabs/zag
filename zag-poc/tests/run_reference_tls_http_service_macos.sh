#!/usr/bin/env bash
# Bounded Network.framework TLS 1.3 HTTP reference gate for Apple Silicon.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
. tests/portable.sh

if [ "$(uname -s):$(uname -m)" != Darwin:arm64 ]; then
    echo 'macOS TLS HTTP reference app requires Apple Silicon macOS' >&2
    exit 2
fi
compiler=${ZNC:-"$root/znc-macos-arm64-parity"}
case "$compiler" in /*) ;; *) compiler="$root/${compiler#./}" ;; esac
test -x "$compiler"
openssl_bin=${OPENSSL:-$(command -v openssl || true)}
if [ -z "$openssl_bin" ]; then
    echo 'macOS TLS HTTP reference app requires openssl for its local fixture' >&2
    exit 2
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/zag-reference-macos-tls-http.XXXXXX")
server_pid=
cleanup() {
    local rc=$?
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    if [ "$rc" -ne 0 ] || [ "${ZAG_TEST_KEEP_WORK:-0}" = 1 ]; then
        printf 'macOS Network TLS HTTP: retained artifacts: %s\n' "$work" >&2
    else
        rm -rf "$work"
    fi
}
trap cleanup EXIT

project="$work/project"
mkdir -p "$project"
printf '%s\n' \
    'name = "macos-network-tls-http"' \
    'version = "0"' \
    'edition = "2027"' >"$project/zag.mod"

build() {
    local output=$1
    cp "$root/tests/reference_apps/macos_network_tls_http/main.zag" "$project/main.zag"
    (cd "$project" && zag_run_bounded 240 "$compiler" main.zag \
        --target macos-arm64 --dynamic -l dispatch \
        -framework Network -framework Security -framework CoreFoundation \
        --no-zagd --no-analyze --no-foreground-cache -o "$output") \
        >"$output.build.out" 2>"$output.build.err"
    test -x "$output"
}

"$openssl_bin" req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
    -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost' \
    -addext 'extendedKeyUsage=serverAuth' \
    -keyout "$work/key.pem" -out "$work/cert.pem" \
    >"$work/cert.out" 2>"$work/cert.err"
"$openssl_bin" x509 -in "$work/cert.pem" -outform DER -out "$work/cert.der"
"$openssl_bin" req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
    -subj '/CN=untrusted' -addext 'subjectAltName=DNS:localhost' \
    -addext 'extendedKeyUsage=serverAuth' \
    -keyout "$work/untrusted-key.pem" -out "$work/untrusted-cert.pem" \
    >"$work/untrusted-cert.out" 2>"$work/untrusted-cert.err"
"$openssl_bin" x509 -in "$work/untrusted-cert.pem" -outform DER \
    -out "$work/untrusted-cert.der"

cat >"$work/server.py" <<'PY'
import pathlib
import os
import select
import socket
import subprocess
import sys
import time

port = int(sys.argv[1])
ready = pathlib.Path(sys.argv[2])
cert = sys.argv[3]
key = sys.argv[4]
openssl_bin = sys.argv[5]
request = b"GET /answer HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n"
response = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n42"
if port == 0:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]

server = subprocess.Popen(
    [
        openssl_bin,
        "s_server",
        "-accept",
        str(port),
        "-cert",
        cert,
        "-key",
        key,
        "-tls1_3",
        "-quiet",
    ],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    bufsize=0,
)

# The fixture already requires this OpenSSL binary for certificate generation;
# use the same TLS implementation for the loopback server so the authority is
# not capped by Apple's older Command Line Tools Python ssl module.
time.sleep(0.1)
if server.poll() is not None:
    _, stderr = server.communicate()
    sys.stderr.buffer.write(stderr)
    raise SystemExit(server.returncode or 2)
ready.write_text(str(port) + "\n")

received = b""
deadline = time.monotonic() + 5.0
while b"\r\n\r\n" not in received and len(received) < 65536:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        break
    readable, _, _ = select.select([server.stdout], [], [], remaining)
    if not readable:
        break
    chunk = os.read(server.stdout.fileno(), 4096)
    if not chunk:
        break
    received += chunk
if not received:
    if server.poll() is None:
        server.terminate()
        server.wait(timeout=5)
    # Trust/hostname-negative clients can abort during TLS setup before any
    # HTTP bytes are delivered. The caller verifies the exact client status.
    raise SystemExit(0)
if received != request:
    if server.poll() is None:
        server.terminate()
        server.wait(timeout=5)
    raise SystemExit(3)

# Force the client to handle a response split across TLS/network callbacks
# instead of accidentally relying on one receive callback.
split = len(response) // 2
server.stdin.write(response[:split])
server.stdin.flush()
time.sleep(0.02)
server.stdin.write(response[split:])
server.stdin.flush()
time.sleep(0.05)
if server.poll() is None:
    server.terminate()
server.wait(timeout=5)
raise SystemExit(0)
PY

port=0

start_server() {
    local ready=$1
    rm -f "$ready"
    python3 "$work/server.py" "$port" "$ready" "$work/cert.pem" "$work/key.pem" "$openssl_bin" \
        >"$ready.out" 2>"$ready.err" &
    server_pid=$!
    local i=0
    while [ "$i" -lt 50 ]; do
        if [ -f "$ready" ]; then
            port=$(cat "$ready")
            [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -gt 0 ]
            return 0
        fi
        if ! kill -0 "$server_pid" 2>/dev/null; then
            cat "$ready.err" >&2 || true
            return 1
        fi
        sleep .1
        i=$((i + 1))
    done
    echo 'macOS TLS HTTP fixture did not become ready' >&2
    return 1
}

build "$work/first"
build "$work/repeat"
cmp "$work/first" "$work/repeat"
file -b "$work/first" | grep -q '^Mach-O 64-bit executable arm64$'
codesign --verify --deep --strict "$work/first"
otool -L "$work/first" >"$work/deps"
grep -Fq '/usr/lib/libSystem.B.dylib' "$work/deps"
grep -Fq '/usr/lib/system/libdispatch.dylib' "$work/deps"
grep -Fq '/System/Library/Frameworks/Network.framework/Versions/A/Network' "$work/deps"
grep -Fq '/System/Library/Frameworks/Security.framework/Versions/A/Security' "$work/deps"
grep -Fq '/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation' "$work/deps"
if grep -Eq 'libssl|libcrypto|Homebrew|/opt/' "$work/deps"; then
    echo 'macOS Network TLS HTTP artifact picked up non-system TLS' >&2
    exit 1
fi

start_server "$work/good.ready"
zag_run_bounded 15 "$work/first" "$port" "$work/cert.der" localhost 1 \
    >"$work/good.out" 2>"$work/good.err"
wait "$server_pid"
server_pid=
printf 'tls http service: backend=Network.framework protocol=TLSv1.3 status=200 body=42 negatives=2\n' \
    | cmp -s - "$work/good.out"
test ! -s "$work/good.err"

port=0
start_server "$work/wrong.ready"
set +e
zag_run_bounded 15 "$work/first" "$port" "$work/cert.der" wrong.invalid 1 \
    >"$work/wrong.out" 2>"$work/wrong.err"
wrong_rc=$?
set -e
wait "$server_pid" 2>/dev/null || true
server_pid=
if [ "$wrong_rc" -ne 4 ] || [ -s "$work/wrong.out" ] || [ -s "$work/wrong.err" ]; then
    echo "macOS Network TLS HTTP wrong-host rejection returned $wrong_rc" >&2
    exit 1
fi

port=0
start_server "$work/untrusted.ready"
set +e
zag_run_bounded 15 "$work/first" "$port" "$work/untrusted-cert.der" localhost 1 \
    >"$work/untrusted.out" 2>"$work/untrusted.err"
untrusted_rc=$?
set -e
wait "$server_pid" 2>/dev/null || true
server_pid=
if [ "$untrusted_rc" -ne 4 ] || [ -s "$work/untrusted.out" ] ||
   [ -s "$work/untrusted.err" ]; then
    echo "macOS Network TLS HTTP wrong-trust rejection returned $untrusted_rc" >&2
    exit 1
fi

echo 'macOS Network TLS HTTP reference: PASS TLS1.3 + Network send/receive + HTTP/1.1 + trust/hostname negatives'
