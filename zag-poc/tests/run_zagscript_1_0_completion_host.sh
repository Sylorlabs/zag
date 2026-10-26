#!/usr/bin/env bash
# Fast host selection regression. Fake only the host probe and bootstrap
# invocation; never run the expensive release suites from this test.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-script-completion-host.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat >"$tmp/bin/uname" <<'EOF'
#!/bin/sh
case "${1:-}" in
    -s) printf '%s\n' "$ZAG_TEST_HOST_SYSTEM" ;;
    -m) printf '%s\n' "$ZAG_TEST_HOST_MACHINE" ;;
    *) exit 2 ;;
esac
EOF
cat >"$tmp/bin/bash" <<'EOF'
#!/bin/sh
if [ "${1:-}" = bootstrap.sh ]; then
    printf '%s\n' "${ZAG_BOOTSTRAP_MEMORY_GUARD:-unset}" >"$ZAG_TEST_BOOTSTRAP_MARKER"
    exit 31
fi
exec /bin/bash "$@"
EOF
chmod +x "$tmp/bin/uname" "$tmp/bin/bash"

check_host() {
    local name=$1 system=$2 machine=$3 want_rc=$4 want_guard=$5
    printf 'keep existing completion evidence\n' >"$tmp/$name.log"
    rm -f "$tmp/$name.marker"
    set +e
    PATH="$tmp/bin:$PATH" ZAG_TEST_HOST_SYSTEM="$system" \
        ZAG_TEST_HOST_MACHINE="$machine" \
        ZAG_TEST_BOOTSTRAP_MARKER="$tmp/$name.marker" \
        ZAG_BOOTSTRAP_MEMORY_GUARD=strict \
        ZAGSCRIPT_1_0_COMPLETION_LOG="$tmp/$name.log" \
        /bin/bash tests/run_zagscript_1_0_completion.sh >"$tmp/$name.out" 2>&1
    local rc=$?
    set -e
    if [ "$rc" -ne "$want_rc" ]; then
        echo "$name: expected status $want_rc, got $rc" >&2
        cat "$tmp/$name.out" >&2
        exit 1
    fi
    if [ "$want_rc" -eq 2 ]; then
        grep -Fq "unsupported host: $system:$machine" "$tmp/$name.out"
        grep -Fxq 'keep existing completion evidence' "$tmp/$name.log"
        test ! -e "$tmp/$name.marker"
    else
        grep -Fxq "$want_guard" "$tmp/$name.marker"
        grep -Fq 'completion: bootstrap failed rc=31' "$tmp/$name.log"
    fi
}

check_host unsupported OpenBSD sparc64 2 unused
check_host macos Darwin arm64 31 off
check_host linux Linux x86_64 31 strict
printf 'ZagScript 1.0 completion host preflight: PASS (unsupported, macOS ARM64, Linux x86-64)\n'
