# Bounded TNN durable-store journal boundary

`std:tnn_store` is a narrow Linux durable-store capability. The current
contract is intentionally limited to a caller-selected root directory, the
writer lock, `journal.tnn`, an atomic checkpoint, and a bounded checkpoint
reader. It is not a general filesystem or database API.

Journal size and journal reads never move the capability's shared `O_APPEND`
descriptor. Each size query and journal/range read opens a fresh read-only
descriptor, performs its private `lseek`/`read` sequence, and closes that
descriptor on every path. This prevents a range reader's cursor from racing
with append, truncation, telemetry, or another reader. `pread64` would be the
natural x86-64 primitive, but syscall 17 is not translated by the checked-in
AArch64 backend; raw `fstat` also has target-specific `struct stat` layouts.
The private-descriptor form therefore preserves the current x86-64/AArch64
source contract without a compiler change.

`tnn_store_read_journal_at` accepts nonnegative offsets and at most one
`tnn_store_max_record_bytes()` output. A range ending at EOF succeeds with
zero or fewer bytes; an offset past EOF fails with the invalid-argument code.
Checkpoint reads retain the explicit not-found status when `checkpoint.tnn`
does not exist.

The source-level cursor gate is:

```sh
bash tests/run_tnn_store_journal_contract.sh
```

This gate proves the no-shared-cursor structure, bounds, and not-found branch;
it does not replace the TNN-owned native x86-64/AArch64 store and concurrent
range tests, which require a fresh compiler and a store root meeting the
large free-space admission policy.
