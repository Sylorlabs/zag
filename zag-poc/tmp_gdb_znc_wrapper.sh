#!/bin/sh
counter=/tmp/zag-gdb-wrapper-count
if [ "$1" != "package" ] || [ "$2" != "registry-lock" ]; then
    exec /home/micah/Desktop/Sylorlabs/zag/zag-poc/znc "$@"
fi
count=0
if [ -f "$counter" ]; then count=$(sed -n '1p' "$counter"); fi
count=$((count + 1))
printf '%s\n' "$count" >"$counter"
if [ "$count" -lt 3 ]; then
    exec /home/micah/Desktop/Sylorlabs/zag/zag-poc/znc "$@"
fi
printf 'gdb invocation %s: %s\n' "$count" "$*" >>/tmp/zag-gdb-wrapper-log
exec gdb -q -batch -x /home/micah/Desktop/Sylorlabs/zag/zag-poc/tmp_gdb_write_probe.txt --args /home/micah/Desktop/Sylorlabs/zag/zag-poc/znc "$@" >>/tmp/zag-gdb-wrapper-log 2>&1
