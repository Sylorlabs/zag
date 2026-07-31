#!/usr/bin/env bash
# Deterministic Zag Script and zagd boundary fuzz smoke.
#
# This is a small dependency-free malformed-input corpus, not a claim of
# coverage-guided fuzzing. Every rejected Script case must fail promptly,
# without a signal, timeout, or executable artifact. The watcher portion feeds
# rapid invalid/valid/rename/delete sequences through the real inotify daemon
# and requires the final stable content hash to win.
set -eu
cd "$(dirname "$0")/.."

ZNC=${ZNC:-"$PWD/znc"}
ZAGD=${ZAGD:-"$PWD/zagd"}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}" ;; esac
case "$ZAGD" in /*) ;; *) ZAGD="$PWD/${ZAGD#./}" ;; esac

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zagscript-fuzz.XXXXXX")
daemon_pid=
cleanup() {
    if [ -n "$daemon_pid" ]; then
        touch "$tmp/project/.zagd.stop" 2>/dev/null || true
        wait "$daemon_pid" 2>/dev/null || true
    fi
    rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

reject_script() {
    name=$1
    source=$2
    src="$tmp/$name.zag"
    out="$tmp/$name.bin"
    log="$tmp/$name.log"
    printf '%s' "$source" > "$src"
    set +e
    timeout 8 "$ZNC" script "$src" -o "$out" --no-zagd --no-foreground-cache >"$log" 2>&1
    status=$?
    set -e
    case "$status" in
        0) echo "Zag Script fuzz: $name unexpectedly compiled" >&2; return 1 ;;
        124|125|126|127) echo "Zag Script fuzz: $name did not reject promptly (status=$status)" >&2; return 1 ;;
    esac
    if [ "$status" -ge 128 ] || [ -e "$out" ]; then
        echo "Zag Script fuzz: $name crashed or left an artifact (status=$status)" >&2
        sed -n '1,12p' "$log" >&2
        return 1
    fi
}

reject_script duplicate_profile 'script; script; say("bad")'
reject_script conflicting_main 'script; fn main() i32 { return 0; } say("bad")'
reject_script unfinished_call 'script; say((("bad")'
reject_script unfinished_collection 'script; let xs = [1, 2, 3; say(xs)'
reject_script mixed_collection 'script; let xs = [1, "two"]; say(xs)'
reject_script bad_try 'script; let value = try; say(value)'
reject_script bad_python_block 'script; if true:\n    say("missing real newline")'
reject_script generated_name_collision 'script; fn __zag_compiler_script_body_7f3a() i32 { return 0; }'

printf '\377script;\nshow("bad")\n' > "$tmp/invalid_utf8.zag"
printf 'script;\nshow("bad")\000\n' > "$tmp/nul_byte.zag"
for name in invalid_utf8 nul_byte; do
    set +e
    timeout 8 "$ZNC" script "$tmp/$name.zag" -o "$tmp/$name.bin" \
        --no-zagd --no-foreground-cache >"$tmp/$name.log" 2>&1
    status=$?
    set -e
    if [ "$status" -eq 0 ] || [ "$status" -eq 124 ] ||
       [ "$status" -ge 128 ] || [ -e "$tmp/$name.bin" ]; then
        echo "Zag Script fuzz: $name boundary failed (status=$status)" >&2
        exit 1
    fi
done

# One valid boundary case proves the corpus is testing rejection rather than a
# generally broken command.
printf 'script;\nsay("fuzz-ok")\n' > "$tmp/valid.zag"
"$ZNC" script "$tmp/valid.zag" -o "$tmp/valid.bin" \
    --no-zagd --no-foreground-cache >/dev/null
test "$("$tmp/valid.bin")" = fuzz-ok

# Exercise the real watcher with deterministic rapid patch-like states. It may
# parse invalid intermediate bytes cheaply, but the final stable hash must be
# the complete renamed file and the daemon must stay alive.
mkdir -p "$tmp/project"
printf 'script;\nsay("initial")\n' > "$tmp/project/app.zag"
"$ZAGD" --root "$tmp/project" --root-source "$tmp/project/app.zag" \
    --mode light --window-ms 20 --max-memory-bytes 134217728 \
    --max-cache-bytes 8388608 --max-workers 1 --notifications errors_only \
    >"$tmp/zagd.log" 2>&1 &
daemon_pid=$!

# Do not race the test corpus against daemon construction.  Once this status
# is published, recursive inotify watches exist and every following save is a
# real watcher event rather than a pre-start file mutation.
ready_deadline=$((SECONDS + 15))
while :; do
    kill -0 "$daemon_pid" 2>/dev/null || {
        echo "Zag Script fuzz: zagd exited before publishing watcher readiness" >&2
        sed -n '1,80p' "$tmp/zagd.log" >&2
        exit 1
    }
    if [ -f "$tmp/project/.zagd.status" ] &&
       grep -q '^state=idle$' "$tmp/project/.zagd.status" &&
       grep -q '^watcher_health=ok$' "$tmp/project/.zagd.status"; then
        break
    fi
    if [ "$SECONDS" -ge "$ready_deadline" ]; then
        echo "Zag Script fuzz: zagd did not publish watcher readiness" >&2
        exit 1
    fi
    sleep 0.05
done

i=0
while [ "$i" -lt 20 ]; do
    printf 'script;\nsay("partial-%s"\n' "$i" > "$tmp/project/app.zag"
    printf 'script;\nsay("stable-%s")\n' "$i" > "$tmp/project/.app.zag.tmp"
    mv "$tmp/project/.app.zag.tmp" "$tmp/project/app.zag"
    if [ $((i % 5)) -eq 0 ]; then
        rm -f "$tmp/project/generated.zag"
        printf 'fn generated_%s() i32 { return %s; }\n' "$i" "$i" \
            > "$tmp/project/generated.zag"
    fi
    i=$((i + 1))
done
printf 'script;\nsay("final-stable")\n' > "$tmp/project/.app.zag.final"
mv "$tmp/project/.app.zag.final" "$tmp/project/app.zag"

deadline=$((SECONDS + 15))
while :; do
    kill -0 "$daemon_pid" 2>/dev/null || {
        echo "Zag Script fuzz: zagd exited during rapid update corpus" >&2
        sed -n '1,80p' "$tmp/zagd.log" >&2
        exit 1
    }
    if [ -f "$tmp/project/.zagd.status" ] &&
       grep -q '^state=idle$' "$tmp/project/.zagd.status" &&
       grep -q 'last_file=.*/app.zag$' "$tmp/project/.zagd.status"; then
        break
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
        echo "Zag Script fuzz: final stable watcher state timed out" >&2
        sed -n '1,120p' "$tmp/project/.zagd.status" >&2 2>/dev/null || true
        exit 1
    fi
    sleep 0.05
done

touch "$tmp/project/.zagd.stop"
wait "$daemon_pid"
daemon_pid=
grep -q '^state=stopped$' "$tmp/project/.zagd.status"

echo "Zag Script/zagd deterministic fuzz smoke: pass"
