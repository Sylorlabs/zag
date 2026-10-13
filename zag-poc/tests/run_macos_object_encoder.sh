#!/usr/bin/env bash
# Independent real-linker validation of object relocation encoding and guards.
set -euo pipefail
cd "$(dirname "$0")/.."
. ./tests/portable.sh
if [ "$(uname -s):$(uname -m)" != Darwin:arm64 ]; then exit 2; fi
compiler=${ZNC:-$(zag_native_compiler "$PWD")}
work=$(mktemp -d "${TMPDIR:-/tmp}/zag-macos-object-encoder.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
zag_run_bounded 240 "$compiler" tests/macos_object_encoder.zag --target macos-arm64 \
    --no-zagd --no-analyze --no-foreground-cache -o "$work/emitter"
cat >"$work/caller.c" <<'C'
#include <stdint.h>
#include <unistd.h>
extern uint64_t zag_object_answer(void);
extern int zag_object_pid(void);
typedef uint64_t (*answer_fn)(void);
extern answer_fn _zag_object_far_pointer(void);
int main(void) {
    if (zag_object_answer()!=42 || zag_object_pid()!=getpid()) return 1;
    answer_fn callback=_zag_object_far_pointer();
    if (callback!=zag_object_answer || callback()!=42) return 2;
    return 0;
}
C
for mode in object archive; do
    zag_run_bounded 30 "$work/emitter" "$work/$mode" "$mode" >"$work/$mode.log" 2>&1
    zag_run_bounded 30 "$work/emitter" "$work/$mode-repeat" "$mode" >>"$work/$mode.log" 2>&1
    cmp "$work/$mode" "$work/$mode-repeat"
    xcrun clang -Wall -Wextra -Werror "$work/caller.c" "$work/$mode" -o "$work/$mode-app"
    zag_run_bounded 30 "$work/$mode-app"
done
echo 'macOS object encoder: PASS deterministic object/archive, far function address, data/import relocations, nine malformed-IR cases'
