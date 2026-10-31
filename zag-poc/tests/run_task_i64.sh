#!/usr/bin/env bash
# Bounded Linux/x86-64 cooperative task/result ABI. This proves direct
# captureless fn(i64)i64 workers, an affine result handle, and polling
# cancellation. The separate run_async_surface.sh proves the bounded source
# spelling; this intrinsic witness remains the lower-level ABI authority.
set -euo pipefail
cd "$(dirname "$0")/.."
ZNC=${ZNC:-./znc}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d /tmp/zag-task-i64.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

project() {
  mkdir -p "$tmp/$1"
  printf 'name = "task-%s"\nversion = "0"\nedition = "2027"\n' "$1" >"$tmp/$1/zag.mod"
}

project valid
cp tests/task_i64.zag "$tmp/valid/main.zag"
(cd "$tmp/valid" && "$ZNC" main.zag --safety=checked --no-zagd --no-analyze --no-foreground-cache -o app >log 2>&1)
test -x "$tmp/valid/app"
readelf -h "$tmp/valid/app" | grep -q 'Type:.*EXEC'
readelf -l "$tmp/valid/app" | grep -q 'GNU_STACK.*RWE' && { echo "task artifact has executable stack" >&2; exit 1; } || true
set +e
timeout 8 "$tmp/valid/app" >"$tmp/valid/out"
rc=$?
set -e
test "$rc" -eq 42
test "$(cat "$tmp/valid/out")" = 'task-i64 result=42 cancellation=1'

reject() {
  local name=$1 needle=$2 source=$3
  project "$name"
  printf '%s\n' "$source" >"$tmp/$name/main.zag"
  if (cd "$tmp/$name" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/$name/log" 2>&1 || test -e "$tmp/$name/out"; then
    echo "task negative unexpectedly compiled: $name" >&2
    cat "$tmp/$name/log" >&2
    exit 1
  fi
  grep -Fq "$needle" "$tmp/$name/log"
}

reject unsafe 'task spawn requires unsafe' \
  'fn worker(h:i64) i64 { return h; } fn main() i32 { let h:*opaque=@taskSpawn(worker,1); return 0; }'
reject worker 'direct non-generic captureless fn(i64) i64 worker' \
  'fn worker(h:i32) i64 { return h as i64; } fn main() i32 { unsafe { let h:*opaque=@taskSpawn(worker,1); return 0; } }'
reject return-shape 'direct non-generic captureless fn(i64) i64 worker' \
  'fn worker(h:i64) void {} fn main() i32 { unsafe { let h:*opaque=@taskSpawn(worker,1); return 0; } }'
reject handle 'task handle operation requires a *opaque handle' \
  'fn main() i32 { unsafe { let x:i64=0; let y:i64=@taskAwait(x); return y as i32; } }'
reject leak 'owned allocation `h` is neither released nor returned' \
  'fn worker(h:i64) i64 { return h; } fn main() i32 { unsafe { let h:*opaque=@taskSpawn(worker,1); return 0; } }'

echo 'task i64: result, affine await, cooperative cancellation, and fail-closed worker boundary pass'
