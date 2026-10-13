#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
znc_bin=${ZNC:-./znc}
tmp_dir=$(mktemp -d /tmp/zag-process-platform.XXXXXX)
container=
trap 'if [ -n "$container" ]; then docker rm -f "$container" >/dev/null; fi; rm -rf "$tmp_dir"' EXIT

# The seed compiles this small driver, which embeds the current lowering. The
# generated tests therefore exercise edited backends, even with an older seed.
"$znc_bin" tests/process_lowering_driver.zag -o "$tmp_dir/lower" --no-analyze --no-zagd --no-foreground-cache >/dev/null
"$znc_bin" tests/process_script_authority.zag -o "$tmp_dir/authority" --no-analyze --no-zagd --no-foreground-cache >/dev/null
"$tmp_dir/authority"

case "$(uname -s):$(uname -m)" in
    Darwin:arm64) native=macos-arm64 ;;
    Linux:aarch64|Linux:arm64) native=linux-arm64 ;;
    Linux:x86_64|Linux:amd64) native=linux-x86_64 ;;
    *) echo "unsupported process test host" >&2; exit 1 ;;
esac
fixtures=(process_platform_capabilities process_wait_native process_isolation_native process_bounded_native process_result_allocation)
for fixture in "${fixtures[@]}"; do
    "$tmp_dir/lower" "tests/$fixture.zag" "$tmp_dir/$fixture-$native" "$native"
    "$tmp_dir/$fixture-$native"
done
if [ "$native" = macos-arm64 ]; then
    "$znc_bin" tests/process_wait_faults.zag -o "$tmp_dir/fault-generator" --no-analyze --no-zagd --no-foreground-cache >/dev/null
    "$tmp_dir/fault-generator" "$tmp_dir/faults"
    "$tmp_dir/faults"
    echo "Darwin injected EINTR/error/stack paths: PASS"
fi
if [ "$native" = linux-arm64 ]; then
    "$tmp_dir/lower" tests/process_wait_eintr_arm64.zag "$tmp_dir/eintr" "$native"
    "$tmp_dir/eintr"
fi

# Explicit opt-in to run both Linux backends on a Docker host. Copy artifacts
# instead of assuming the daemon can bind-mount the host's temporary directory.
if [ "${PROCESS_TEST_LINUX:-0}" = 1 ]; then
    for target in linux-arm64 linux-x86_64; do
        platform=linux/arm64
        if [ "$target" = linux-x86_64 ]; then platform=linux/amd64; fi
        extra=
        if [ "$target" = linux-arm64 ]; then extra=process_wait_eintr_arm64; fi
        container=$(docker create --platform "$platform" -e TARGET="$target" -e EXTRA="$extra" \
            "${PROCESS_TEST_IMAGE:-debian:bookworm-slim}" sh -ec '
                for test in process_platform_capabilities process_wait_native process_isolation_native process_bounded_native process_result_allocation $EXTRA; do
                    /tmp/$test-$TARGET
                done')
        for fixture in "${fixtures[@]}" $extra; do
            "$tmp_dir/lower" "tests/$fixture.zag" "$tmp_dir/$fixture-$target" "$target"
            docker cp "$tmp_dir/$fixture-$target" "$container:/tmp/"
        done
        docker start -a "$container"
        rc=$(docker inspect --format '{{.State.ExitCode}}' "$container")
        docker rm "$container" >/dev/null
        container=
        test "$rc" -eq 0
        echo "$target executed process tests: PASS"
    done
fi

# A freshly rebuilt CLI additionally proves the real std-body authority walk
# and Script lowering; the small driver intentionally bypasses CLI checks.
if [ -n "${PROCESS_TEST_CLI:-}" ]; then
    "$PROCESS_TEST_CLI" tests/script_frontend/process_bounded.zag -o "$tmp_dir/script" --no-analyze --no-zagd --no-foreground-cache >/dev/null
    "$tmp_dir/script"
    for fixture in process_script_bridge_spoof process_script_owner_spoof; do
        if "$PROCESS_TEST_CLI" "tests/$fixture.zag" -o "$tmp_dir/spoof" --no-analyze --no-zagd --no-foreground-cache >"$tmp_dir/rejected" 2>&1; then
            echo "accepted forged process bridge: $fixture" >&2; exit 1
        fi
        grep -q 'znc script helper body:.*_zag_process_wait_readable' "$tmp_dir/rejected"
        test ! -e "$tmp_dir/spoof"
    done
    echo "Script CLI process authority: PASS"
fi

if grep -En 'Darwin|EWOULDBLOCK|0 - 35|kqueue|Seatbelt|N09|timerfd|epoll|_zag_raw_syscall' selfhost/std/process.zag; then
    echo "shared process supervisor contains platform-specific assumptions" >&2
    exit 1
fi

echo "process platform: PASS (kernel sandbox unsupported)"
