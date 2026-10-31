#!/usr/bin/env bash
# Source-level contract gate for std:tnn_store journal cursor isolation.
# This gate intentionally does not compile or execute the TNN store; the
# TNN-owned store gate remains responsible for native x86-64/AArch64 evidence.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
source="$root/std/tnn_store.zag"
test -f "$source"

function_body() {
    local name=$1
    awk -v wanted="fn $name" '
        index($0, wanted "(") == 1 { active=1 }
        active {
            line=$0
            opens=gsub(/\{/, "{", line)
            closes=gsub(/\}/, "}", line)
            depth += opens - closes
            print
            if (depth == 0 && (opens + closes) > 0) { exit }
        }
    ' "$source"
}

size_body=$(function_body tnn_store_journal_size)
read_body=$(function_body tnn_store_read_journal)
range_body=$(function_body tnn_store_read_journal_at)

grep -q 'tnn_store_open_child(store.root_fd' <<<"$size_body"
grep -q '_zag_raw_syscall(8, reader_fd, 0, 2' <<<"$size_body"
! grep -q 'journal_fd, 0, 2' <<<"$size_body"

for body in "$read_body" "$range_body"; do
    grep -q 'tnn_store_open_journal_reader(store.\*)' <<<"$body"
    grep -q '_zag_raw_syscall(0, reader_fd' <<<"$body"
    grep -q '_zag_raw_syscall(3, reader_fd' <<<"$body"
done

! grep -q '_zag_raw_syscall(8, store.\*\.journal_fd' "$source"
! grep -q '_zag_raw_syscall(0, store.\*\.journal_fd' "$source"
grep -q 'offset < 0' <<<"$range_body"
grep -q 'output.len > tnn_store_max_record_bytes()' <<<"$range_body"
grep -q 'tnn_store_status_not_found' "$source"
grep -q 'fd == (0 - 2)' "$source"

printf '%s\n' 'TNN store journal contract: pass (private cursors, bounded range, not-found path)'
