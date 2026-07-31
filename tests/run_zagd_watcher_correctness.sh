#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

tmp=$(mktemp -d /tmp/zagd-watcher-correctness.XXXXXX)
daemon_pid=
writer_pid=
trap 'rc=$?; if [ "$rc" -ne 0 ] && [ -f "$tmp/project/.zagd.status" ]; then echo "watcher status at failure:" >&2; sed -n "1,80p" "$tmp/project/.zagd.status" >&2; fi; if [ -n "$writer_pid" ]; then kill "$writer_pid" 2>/dev/null || true; wait "$writer_pid" 2>/dev/null || true; fi; if [ -n "$daemon_pid" ]; then kill "$daemon_pid" 2>/dev/null || true; fi; rm -rf "$tmp"; exit "$rc"' EXIT
compiler=${ZNC:-"$(pwd)/znc"}
case "$compiler" in /*) ;; *) compiler="$(pwd)/${compiler#./}" ;; esac

"$compiler" tests/zagd_linux_test.zag -o "$tmp/linux-test" --no-zagd --no-analyze >/dev/null
"$tmp/linux-test"
"$compiler" selfhost/zagd_daemon.zag -o "$tmp/zagd" --no-zagd --no-analyze >/dev/null
ln -s "$compiler" "$tmp/znc"

project="$tmp/project"
mkdir "$project"
printf '[package]\nname = "watcher-correctness"\nversion = "0.0.1"\n' >"$project/zag.mod"
printf 'fn main() i32 { return 0; }\n' >"$project/app.zag"
"$tmp/zagd" --root "$project" --root-source "$project/app.zag" --mode light --window-ms 100 &
daemon_pid=$!
for _ in $(seq 1 200); do
    grep -q '^state=idle$' "$project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done

# Seed one tracked file, then prove an exhausted stability window never advances
# the published event count or snapshot.
printf 'fn churn() i32 { return 0; }\n' >"$project/churn.zag"
for _ in $(seq 1 300); do
    grep -q 'file=churn.zag' "$project/.zag-cache/zagd/snapshot.record" 2>/dev/null && break
    sleep 0.01
done
grep -q 'file=churn.zag' "$project/.zag-cache/zagd/snapshot.record"
before_snapshot=$(sed -n 's/^snapshot_first=//p' "$project/.zagd.status")
(
    for i in $(seq 1 200); do
        printf 'fn churn() i32 { return %s; }\n' "$i" >"$project/churn.zag"
        sleep 0.01
    done
    printf 'fn churn() i32 { return 777; }\n' >"$project/churn.zag"
) &
writer_pid=$!
for _ in $(seq 1 400); do
    grep -q '^state=stabilizing$' "$project/.zagd.status" 2>/dev/null && break
    sleep 0.005
done
grep -q '^state=stabilizing$' "$project/.zagd.status"
test "$(sed -n 's/^snapshot_first=//p' "$project/.zagd.status")" = "$before_snapshot"
wait "$writer_pid"
writer_pid=
for _ in $(seq 1 500); do
    if grep -q '^state=idle$' "$project/.zagd.status" 2>/dev/null &&
       test "$(sed -n 's/^snapshot_first=//p' "$project/.zagd.status")" != "$before_snapshot"; then
        break
    fi
    sleep 0.01
done
grep -q '^state=idle$' "$project/.zagd.status"
test "$(sed -n 's/^snapshot_first=//p' "$project/.zagd.status")" != "$before_snapshot"

# The safe policy ignores project-internal file and directory symlinks and does
# not watch or hash their targets outside the project root.
printf 'fn external() i32 { return 9; }\n' >"$tmp/external.zag"
mkdir "$tmp/external-dir"
printf 'fn hidden() i32 { return 8; }\n' >"$tmp/external-dir/hidden.zag"
symlink_snapshot=$(sed -n 's/^snapshot_first=//p' "$project/.zagd.status")
symlink_files=$(sed -n 's/^snapshot_file_count=//p' "$project/.zagd.status")
ln -s "$tmp/external.zag" "$project/linked.zag"
ln -s "$tmp/external-dir" "$project/linked-dir"
sleep 0.2
test "$(sed -n 's/^snapshot_first=//p' "$project/.zagd.status")" = "$symlink_snapshot"
test "$(sed -n 's/^snapshot_file_count=//p' "$project/.zagd.status")" = "$symlink_files"
printf 'fn external() i32 { return 10; }\n' >"$tmp/external.zag"
sleep 0.1
test "$(sed -n 's/^snapshot_first=//p' "$project/.zagd.status")" = "$symlink_snapshot"

# The explicit recovery hint executes the same stable full-tree rescan used for
# IN_Q_OVERFLOW. Its persisted source set excludes both symlinks.
printf rescan >"$project/.zagd.rescan"
for _ in $(seq 1 300); do
    grep -q '^last_file=<explicit-rescan>$' "$project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
grep -q '^last_file=<explicit-rescan>$' "$project/.zagd.status"
grep -q '^last_change=unknown$' "$project/.zagd.status"
grep -q 'file=app.zag' "$project/.zag-cache/zagd/snapshot.record"
grep -q 'file=churn.zag' "$project/.zag-cache/zagd/snapshot.record"
if grep -q 'linked' "$project/.zag-cache/zagd/snapshot.record"; then
    echo "symlink unexpectedly entered rescan snapshot" >&2
    exit 1
fi

printf stop >"$project/.zagd.stop"
wait "$daemon_pid"
daemon_pid=
grep -q '^state=stopped$' "$project/.zagd.status"
echo "zagd watcher correctness: pass"
