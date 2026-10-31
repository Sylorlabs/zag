#!/usr/bin/env bash
# Focused proof for the first language async surface. It proves only
# captureless fn()i64/fn(i64)i64 -> await(handle) on Linux x86-64; cancellation
# remains explicit through @taskCancel and generic futures/schedulers are not
# claimed.
set -euo pipefail
cd "$(dirname "$0")/.."
ZNC=${ZNC:-./znc}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d /tmp/zag-async-surface.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

printf 'name = "async-surface"\nversion = "0"\nedition = "2027"\n' >"$tmp/zag.mod"
cp tests/async_task_i64.zag "$tmp/main.zag"
(
  cd "$tmp"
  "$ZNC" main.zag --safety=checked --no-zagd --no-analyze --no-foreground-cache -o app >build.log 2>&1
)
test -x "$tmp/app"
readelf -h "$tmp/app" | grep -q 'Class:.*ELF64'
readelf -h "$tmp/app" | grep -Eq 'Machine:.*(X86-64|x86-64)'
set +e
timeout 8 "$tmp/app" >"$tmp/out"
rc=$?
set -e
test "$rc" -eq 42

reject() {
  local name=$1 needle=$2 source=$3
  mkdir -p "$tmp/$name"
  printf 'name = "async-%s"\nversion = "0"\nedition = "2027"\n' "$name" >"$tmp/$name/zag.mod"
  printf '%s\n' "$source" >"$tmp/$name/main.zag"
  set +e
  (cd "$tmp/$name" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/$name/log" 2>&1
  local status=$?
  set -e
  test "$status" -ne 0
  test ! -e "$tmp/$name/out"
  grep -Fq "$needle" "$tmp/$name/log"
}

reject unsafe 'async task spawn requires unsafe' \
  'async fn worker(x:i64) i64 { return x; } fn main() i32 { let h:*opaque=worker(1); return 0; }'
reject signature 'async fn requires a captureless non-generic fn() i64 or fn(i64) i64 declaration' \
  'async fn worker(x:i32) i64 { return x as i64; } fn main() i32 { unsafe { let h:*opaque=worker(1); return 0; } }'
reject generic_declaration 'async fn requires a captureless non-generic fn() i64 or fn(i64) i64 declaration' \
  'async fn worker[T](x:T) i64 { return 41; } fn main() i32 { unsafe { let h:*opaque=worker[i64](1); return 0; } }'
reject zero_arity "passes 1 argument(s), expected 0" \
  'async fn worker() i64 { return 41; } fn main() i32 { unsafe { let h:*opaque=worker(1); return 0; } }'
reject raw_zero_worker 'direct non-generic captureless fn(i64) i64 worker' \
  'fn worker() i64 { return 41; } fn main() i32 { unsafe { let h:*opaque=@taskSpawn(worker,1); return 0; } }'
reject function_value_worker 'direct non-generic captureless fn(i64) i64 worker' \
  'async fn worker(x:i64) i64 { return x; } fn main() i32 { unsafe { let f:fn(i64) i64=worker; let h:*opaque=@taskSpawn(f,1); return 0; } }'
reject await_unsafe 'task handle operation requires unsafe' \
  'async fn worker(x:i64) i64 { return x; } fn main() i32 { let h:*opaque=worker(1); let x:i64=await(h); return x as i32; }'
reject await_use_after_consume 'use after free of named allocation `h`' \
  'async fn worker(x:i64) i64 { return x; } fn main() i32 { unsafe { let h:*opaque=worker(1); let x:i64=await(h); let c:i64=cancel(h); return c as i32; } }'
reject compiler_owned 'taskSpawnValue is compiler-owned and cannot be called from source' \
  'fn worker(x:i64) i64 { return x; } fn main() i32 { unsafe { let h:*opaque=@taskSpawnValue(worker,1); return 0; } }'
reject await_shape 'await` requires one parenthesized task handle' \
  'fn main() i32 { unsafe { return await 1; } }'
reject cancel_unsafe 'task handle operation requires unsafe' \
  'fn main() i32 { let h:*opaque=null; let rc:i64=cancel(h); return rc as i32; }'

echo 'async surface: TaskI64 async/await lowering and fail-closed boundaries pass'
