#!/usr/bin/env bash
# tests/test_lsp.sh — basic LSP protocol smoke tests for zag-lsp
#
# Build zag-lsp first:
#   ./znc selfhost/lsp/zag-lsp.zag -o zag-lsp
#
# Run:
#   bash tests/test_lsp.sh

set -euo pipefail
cd "$(dirname "$0")/.."

ZAG_LSP="${ZAG_LSP:-./zag-lsp}"
PASS=0
FAIL=0

# Helper: send a sequence of LSP message bodies; compute Content-Length for each.
lsp_exchange() {
    local input=""
    for body in "$@"; do
        local len="${#body}"
        input+="Content-Length: ${len}\r\n\r\n${body}"
    done
    printf "$input" | "$ZAG_LSP" 2>/dev/null
}

check() {
    local label="$1"
    local actual="$2"
    local expected="$3"
    if echo "$actual" | grep -qF "$expected"; then
        echo "  ok  $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $label"
        echo "        expected to find: $expected"
        FAIL=$((FAIL + 1))
    fi
}

echo "── LSP smoke tests ──────────────────────────────────────────────────────────"

# Build the LSP binary if not present
if [[ ! -x "$ZAG_LSP" ]]; then
    echo "Building zag-lsp..."
    ./znc selfhost/lsp/zag-lsp.zag -o zag-lsp
fi

# ── Test 1: initialize ─────────────────────────────────────────────────────────
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"rootUri":null}}'
RESULT=$(lsp_exchange "$INIT")
check "initialize returns capabilities" "$RESULT" '"hoverProvider":true'
check "initialize returns textDocumentSync" "$RESULT" '"textDocumentSync":1'
check "initialize returns definitionProvider" "$RESULT" '"definitionProvider":true'

# ── Test 2: shutdown / exit ────────────────────────────────────────────────────
SHUTDOWN='{"jsonrpc":"2.0","id":2,"method":"shutdown","params":{}}'
EXIT_MSG='{"jsonrpc":"2.0","method":"exit","params":{}}'
RESULT=$(lsp_exchange "$INIT" "$SHUTDOWN" "$EXIT_MSG")
check "shutdown returns null result" "$RESULT" '"id":2,"result":null'

# ── Test 3: didOpen + publishDiagnostics ───────────────────────────────────────
SRC='fn add(a: i32, b: i32) i32 { return a + b; }'
OPEN='{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///add.zag","languageId":"zag","version":1,"text":"'"$SRC"'"}}}'
RESULT=$(lsp_exchange "$INIT" "$OPEN" "$EXIT_MSG")
check "didOpen pushes diagnostics" "$RESULT" '"method":"textDocument/publishDiagnostics"'
check "diagnostics are for the opened URI" "$RESULT" '"uri":"file:///add.zag"'

# ── Test 3b: semantic effect violation is published ──────────────────────────
BAD_SRC='extern fn do_io() void @io; fn bad() void @pure { do_io(); }'
BAD_OPEN='{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///bad.zag","languageId":"zag","version":1,"text":"'"$BAD_SRC"'"}}}'
RESULT=$(lsp_exchange "$INIT" "$BAD_OPEN" "$EXIT_MSG")
check "effect violation becomes an LSP diagnostic" "$RESULT" 'effect violation: I/O not allowed'
check "effect diagnostic has Zag source" "$RESULT" '"source":"zag"'

# ── Test 4: hover over function name ──────────────────────────────────────────
# Position 3 = 'a' in 'add' (fn |a|dd...)
HOVER='{"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///add.zag"},"position":{"line":0,"character":3}}}'
RESULT=$(lsp_exchange "$INIT" "$OPEN" "$HOVER" "$EXIT_MSG")
check "hover returns function signature" "$RESULT" 'fn add('
check "hover includes return type" "$RESULT" 'i32'
check "hover response has contents" "$RESULT" '"contents":'

# ── Test 5: definition ─────────────────────────────────────────────────────────
DEF='{"jsonrpc":"2.0","id":4,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///add.zag"},"position":{"line":0,"character":3}}}'
RESULT=$(lsp_exchange "$INIT" "$OPEN" "$DEF" "$EXIT_MSG")
check "definition returns a location" "$RESULT" '"uri":"file:///add.zag"'
check "definition returns a range" "$RESULT" '"range":'
check "definition points to line 0" "$RESULT" '"line":0'

# ── Test 6: unknown method returns error ──────────────────────────────────────
UNK='{"jsonrpc":"2.0","id":5,"method":"unknown/method","params":{}}'
RESULT=$(lsp_exchange "$INIT" "$UNK" "$EXIT_MSG")
check "unknown method returns error" "$RESULT" '"error":'

# ── Test 7: hover on unknown identifier returns word (plain text) ─────────────
# Position 7 = 'a' parameter in fn add(a...)
HOVER3='{"jsonrpc":"2.0","id":7,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///add.zag"},"position":{"line":0,"character":7}}}'
RESULT=$(lsp_exchange "$INIT" "$OPEN" "$HOVER3" "$EXIT_MSG")
check "hover on parameter returns word hover" "$RESULT" '"contents":'

# ── Test 8: initialized notification (no response expected) ───────────────────
INITED='{"jsonrpc":"2.0","method":"initialized","params":{}}'
RESULT=$(lsp_exchange "$INIT" "$INITED" "$SHUTDOWN" "$EXIT_MSG")
check "initialized notification accepted (no error)" "$RESULT" '"id":2,"result":null'

echo "── LSP tests: pass=$PASS fail=$FAIL ─────────────────────────────────────────"
if [[ $FAIL -gt 0 ]]; then exit 1; fi
exit 0
