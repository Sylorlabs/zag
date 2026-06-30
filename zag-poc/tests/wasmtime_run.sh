#!/usr/bin/env bash
# Run a Zag-emitted .wasm under wasmtime with env::{print_*} host stubs.
# Builds tests/wasm_invoke_host once via cargo when needed.
#
# Usage:
#   wasmtime_run.sh <file.wasm> [expected-i32]
# When expected-i32 is given, exits 0 only if main() returns that value.
# When omitted, prints the i32 return value to stdout.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOST_DIR="$SCRIPT_DIR/wasm_invoke_host"
HOST_BIN="$HOST_DIR/target/release/wasm_invoke_host"

ensure_wasmtime() {
    if command -v wasmtime >/dev/null 2>&1; then
        return 0
    fi
    local wt_home="${WASMTIME_HOME:-$HOME/.wasmtime}"
    if [ -x "$wt_home/bin/wasmtime" ]; then
        export PATH="$wt_home/bin:$PATH"
        return 0
    fi
    return 1
}

ensure_host() {
    if [ -x "$HOST_BIN" ]; then
        return 0
    fi
    if ! command -v cargo >/dev/null 2>&1; then
        return 1
    fi
    echo "  ..  building wasm_invoke_host (one-time cargo build)..." >&2
    (cd "$HOST_DIR" && cargo build --release --quiet) || return 1
    [ -x "$HOST_BIN" ]
}

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "usage: wasmtime_run.sh <file.wasm> [expected-i32]" >&2
    exit 2
fi

if ! ensure_wasmtime; then
    echo "wasmtime not found (install: curl -sSf https://wasmtime.dev/install.sh | bash)" >&2
    exit 127
fi

if ! ensure_host; then
    echo "wasm_invoke_host missing and cargo build failed" >&2
    exit 127
fi

exec "$HOST_BIN" "$@"