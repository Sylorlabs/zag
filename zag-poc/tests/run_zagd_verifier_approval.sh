#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")/.."

ZNC_BIN=${ZNC:-./znc}
case "$ZNC_BIN" in
    /*) ;;
    *) ZNC_BIN="$PWD/${ZNC_BIN#./}" ;;
esac
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zagd-verifier-approval.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/state"

"$ZNC_BIN" selfhost/zagd_verifier_approval_fixture.zag -o "$tmp/fixture" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
generation=$($tmp/fixture "$tmp/state")
if ! [[ "$generation" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]]; then
    echo "zagd verifier approval: malformed fixture generation identity" >&2
    exit 1
fi

record="$tmp/state/.zag-cache/zagd/verifier-approval.record"
test -f "$record"
grep -q '^format=zagd-verifier-approval-v2$' "$record"
grep -q '^approved=true$' "$record"
grep -q '^executable_authority=false$' "$record"
grep -q '^execution_enabled=false$' "$record"
grep -q '^verifier_independent=false$' "$record"
grep -Eq '^compiler_identity=[0-9]+[[:blank:]][0-9]+[[:blank:]][0-9]+$' "$record"
grep -q '^trust_mode=stable$' "$record"
grep -Eq '^verifier_identity=[0-9]+[[:blank:]][0-9]+[[:blank:]][0-9]+$' "$record"
grep -Eq '^policy_identity=[0-9]+[[:blank:]][0-9]+[[:blank:]][0-9]+$' "$record"
grep -q '^basis=reviewed-command-v1$' "$record"
grep -q "^generation=$(printf '%s' "$generation" | tr ':' '\t')$" "$record"
if grep -Eq '^execution_enabled=true$|^executable_authority=true$' "$record"; then
    echo "zagd verifier approval: approval unexpectedly enabled execution" >&2
    exit 1
fi

grep -q 'execution_enabled=false' selfhost/zagd_generation.zag
grep -q 'zagd_generation_approve(root, compiler, candidate.identity)' selfhost/zagd_verifier_approval_fixture.zag
grep -q 'znc verifier: usage is' selfhost/native/znc.zag
grep -q -- '--verifier-approve' selfhost/zagd_daemon.zag
grep -q 'zagd_running_exe_path' selfhost/zagd_daemon.zag
grep -q 'zagd_sys_readlink' selfhost/zagd_daemon.zag
grep -q 'approval_policy.valid == 0' selfhost/zagd_daemon.zag

# The public reviewed-mode command is exercised against explicitly supplied
# freshly built products.  Release/bootstrap callers provide both products;
# the source-only fixture above remains useful for portable development when a
# product pair is not available yet.
product_znc=${ZNC_PRODUCT:-}
product_zagd=${ZAGD_PRODUCT:-}
public_daemon=0
public_znc=0
if [[ -n "$product_zagd" ]]; then
    test -x "$product_zagd"
    # The source fixture intentionally exercises the legacy codec API.  The
    # public daemon command must instead approve a registry it initialized
    # with its actual sibling compiler image and effective policy context.
    public_root="$tmp/public-state"
    mkdir -p "$public_root"
    printf 'name = "public-approval"\n' >"$public_root/zag.mod"
    # Keep the daemon's effective policy at the documented default so the
    # approval command's independently parsed project policy matches it.
    "$product_zagd" --root "$public_root" >"$tmp/daemon-public.out" 2>&1 &
    public_pid=$!
    for _ in $(seq 1 500); do
        [[ -s "$public_root/.zagd.status" ]] && break
        sleep 0.01
    done
    grep -Eq '^generation_verifier_first=[0-9]+$' "$public_root/.zagd.status"
    grep -Eq '^generation_verifier_second=[0-9]+$' "$public_root/.zagd.status"
    grep -Eq '^generation_verifier_bytes=[0-9]+$' "$public_root/.zagd.status"
    public_generation=$(awk -F= '
        /^generation_selected_first=/ { first=$2 }
        /^generation_selected_second=/ { second=$2 }
        /^generation_selected_bytes=/ { bytes=$2 }
        END { if (first != "" && second != "" && bytes != "") print first ":" second ":" bytes }
    ' "$public_root/.zagd.status")
    if [[ -z "$public_generation" ]]; then
        echo 'zagd verifier approval: public daemon did not publish a bound generation' >&2
        kill "$public_pid" 2>/dev/null || true
        wait "$public_pid" 2>/dev/null || true
        exit 1
    fi
    printf stop >"$public_root/.zagd.stop"
    for _ in $(seq 1 500); do
        if ! kill -0 "$public_pid" 2>/dev/null; then break; fi
        sleep 0.01
    done
    if kill -0 "$public_pid" 2>/dev/null; then kill "$public_pid" 2>/dev/null || true; fi
    wait "$public_pid" 2>/dev/null || true
    "$product_zagd" --verifier-approve "$public_generation" --root "$public_root" >"$tmp/daemon-approve.out"
    grep -q 'reviewed verifier approval recorded' "$tmp/daemon-approve.out"
    public_record="$public_root/.zag-cache/zagd/verifier-approval.record"
    grep -q '^approved=true$' "$public_record"
    if "$product_zagd" --verifier-approve '1:2:3:4' --root "$public_root" >/dev/null 2>&1; then
        echo 'zagd verifier approval: malformed public identity unexpectedly accepted' >&2
        exit 1
    fi
    malformed_root="$tmp/malformed-policy"
    mkdir -p "$malformed_root"
    printf 'trust_mode=unsafe\n' >"$malformed_root/.zagd.conf"
    set +e
    "$product_zagd" --verifier-approve '1:2:3' --root "$malformed_root" >"$tmp/malformed-policy.out" 2>&1
    malformed_rc=$?
    set -e
    if [[ "$malformed_rc" != 4 ]] || ! grep -q 'invalid .zagd.conf' "$tmp/malformed-policy.out"; then
        echo 'zagd verifier approval: malformed existing policy did not fail closed' >&2
        exit 1
    fi
    public_daemon=1
fi
if [[ -n "$product_znc" && -n "$product_zagd" ]]; then
    test -x "$product_znc"
    "$product_znc" verifier approve "$public_generation" --root "$public_root" >"$tmp/approve.out"
    grep -q 'reviewed approval recorded' "$tmp/approve.out"
    grep -q '^approved=true$' "$public_record"
    if "$product_znc" verifier approve '1:2:3:4' --root "$public_root" >/dev/null 2>&1; then
        echo 'zagd verifier approval: malformed public identity unexpectedly accepted' >&2
        exit 1
    fi
    public_znc=1
fi
if [[ "$public_znc" == 1 ]]; then
    echo 'zagd verifier approval: pass (public znc+zagd reviewed command; execution remains disabled)'
elif [[ "$public_daemon" == 1 ]]; then
    echo 'zagd verifier approval: pass (public zagd reviewed command; znc product deferred; execution remains disabled)'
else
    echo 'zagd verifier approval: pass (metadata fixture; public product command deferred; execution remains disabled)'
fi

# A daemon launched through PATH and a symlink must bind to the actual image
# resolved by /proc/self/exe, not to ./znc in whichever directory launched it.
# Use two distinct fake cwd compilers; the status identity must remain stable.
if [[ -n "$product_zagd" && -x "$(dirname "$product_zagd")/znc" ]]; then
    image_tmp="$tmp/image-binding"
    mkdir -p "$image_tmp/bin" "$image_tmp/project" "$image_tmp/launch-a" "$image_tmp/launch-b"
    ln -s "$product_zagd" "$image_tmp/bin/zagd-path"
    printf 'name = "image-binding"\n' >"$image_tmp/project/zag.mod"
    printf 'fake compiler A\n' >"$image_tmp/launch-a/znc"
    printf 'fake compiler B\n' >"$image_tmp/launch-b/znc"
    run_image_daemon() {
        local launch=$1 output=$2
        (cd "$launch" && PATH="$image_tmp/bin:$PATH" zagd-path --mode light --root "$image_tmp/project") >"$output" 2>&1 &
        local daemon_pid=$!
        for _ in $(seq 1 500); do
            [[ -s "$image_tmp/project/.zagd.status" ]] && break
            sleep 0.01
        done
        if ! grep -q '^generation_compiler_bytes=' "$image_tmp/project/.zagd.status"; then
            echo 'zagd verifier approval: PATH/symlink daemon did not publish compiler identity' >&2
            kill "$daemon_pid" 2>/dev/null || true
            wait "$daemon_pid" 2>/dev/null || true
            return 1
        fi
        local identity
        identity=$(grep '^generation_compiler_\(first\|second\|bytes\)=' "$image_tmp/project/.zagd.status" | sort)
        printf '%s\n' "$identity" >"$output.identity"
        printf stop >"$image_tmp/project/.zagd.stop"
        for _ in $(seq 1 500); do
            if ! kill -0 "$daemon_pid" 2>/dev/null; then break; fi
            sleep 0.01
        done
        if kill -0 "$daemon_pid" 2>/dev/null; then
            kill "$daemon_pid" 2>/dev/null || true
        fi
        wait "$daemon_pid" 2>/dev/null || true
    }
    run_image_daemon "$image_tmp/launch-a" "$image_tmp/a.out"
    run_image_daemon "$image_tmp/launch-b" "$image_tmp/b.out"
    if ! cmp -s "$image_tmp/a.out.identity" "$image_tmp/b.out.identity"; then
        echo 'zagd verifier approval: compiler identity changed with PATH/symlink launch cwd' >&2
        exit 1
    fi
    echo 'zagd verifier approval: PATH/symlink image binding pass'
fi
