# Bounded Linux filesystem and concurrent indexer slice

`std:linux_fs` is a pure-Zag, libc-free Linux x86-64 filesystem foundation.
It is intentionally smaller than a general file or path library.  Its public
contract covers one retained directory descriptor, one bounded non-recursive
listing, and bounded reads of direct regular-file children.

## Public boundary

`linux_fs_directory_open(path)` validates a nonempty path of at most 4095
bytes, rejects embedded NULs and any `..` component, uses `newfstatat` with
`AT_SYMLINK_NOFOLLOW`, and then opens a real directory with `O_DIRECTORY`,
`O_NOFOLLOW`, and `O_CLOEXEC`.  A successful
`LinuxFsDirectoryResult` is moved with `linux_fs_directory_take`; the resulting
`LinuxFsDirectory` is closed exactly once with `linux_fs_directory_close`.
Second takes and second closes fail with `linux_fs_status_invalid_state()`.

`linux_fs_list_regular_children_bounded` uses `getdents64` and caller-owned
entry/name/scratch buffers.  The caller supplies all of these bounds:

- 1 through 1024 entry slots;
- 2 through 256 bytes for each entry name;
- 256 through 65,536 bytes of getdents scratch space; and
- 1 through 1024 getdents calls.

The listing skips only `.` and `..`, accepts direct regular files, copies each
name with a trailing NUL, and sorts successful results bytewise.  It does not
descend.  A child directory fails with `linux_fs_status_traversal()`, a symlink
with `linux_fs_status_symlink()`, a capacity exhaustion with
`linux_fs_status_limit()`, and a malformed kernel record with
`linux_fs_status_malformed()`.  Unknown `d_type` values are resolved with a
nofollow `newfstatat` check rather than guessed.

`linux_fs_read_regular_at_prepared` is the allocation-free worker boundary.
The parent supplies a retained directory fd, a prevalidated NUL-terminated
direct-child name and its capacity, an output buffer, a maximum file size, and
a maximum read-call count.  The function:

1. rejects empty names, slash-containing names, `.`/`..`, missing terminators,
   and inconsistent name capacities;
2. calls relative `openat` with `O_NONBLOCK`, `O_NOFOLLOW`, and `O_CLOEXEC`;
3. uses `fstat` to require a regular file and a nonnegative size no larger than
   the caller's limit;
4. performs a bounded partial-read/EINTR loop;
5. probes one byte past the observed size to reject concurrent growth without
   writing past the output buffer; and
6. closes its private descriptor on every success and failure path.

Successful reads return byte count, syscall count, and a deterministic
position-weighted byte checksum.  The checksum is an application accounting
witness, not a cryptographic digest.  Kernel failures retain their negative
Linux errno.  Library validation and limit failures use the `-7101` through
`-7108` status family exposed by the module.

## Reference application

`tests/reference_apps/concurrent_file_indexer/main.zag` indexes a fixed-shape
test directory containing exactly three direct regular files.  The parent
lists and sorts the names, prepares one disjoint task, result, name, and
64-byte output region per file in a private 8 KiB mapping, then starts three
workers with `@threadSpawn(index_worker, task_index)`.  The worker is a direct,
captureless `fn(i64) void`; its only argument is the copied task index.  A futex
gate releases the workers after every handle exists, and the parent consumes
all three handles with `@threadJoin` before reading results or unmapping memory.

The fixture's exact output is:

```text
a.txt bytes=6 checksum=1610
b.txt bytes=12 checksum=6906
c.txt bytes=24 checksum=27585
total files=3 bytes=42 checksum=36101
```

No worker calls the Zag allocator, `mmap`, `munmap`, a print routine, or a
directory iterator.  Workers share the retained directory fd read-only and
write only their indexed result/output slots.  Parent-side allocation
accounting and checked `munmap`/`close` results cover cleanup.

## Evidence and explicit limits

Run:

```sh
bash tests/run_reference_concurrent_file_indexer.sh
```

The gate builds the edition-2027 app twice, requires byte-identical static
ELF64 x86-64 `ET_EXEC` artifacts with no interpreter, compares exact output,
and exercises missing/inaccessible roots, a root symlink, a `..` traversal
path, child symlinks/directories, entry overflow, file-size overflow, and an
inaccessible file.  Its focused contract program additionally checks sorted
listing, missing and traversal-like prepared names, name-capacity validation,
descriptor liveness, one-time take/close, closed-handle rejection, and runtime
allocator balance.  When `strace` is installed, the gate requires observed
`clone`, `futex`, `getdents64`, `openat`, `read`, and `close` syscalls.

This remains an `unsafe`, join-only thread demonstration.  Global task/result
pointers and the plain global gate rely on the documented raw thread contract;
the compiler does not infer race freedom, lifetime handoff, or a language-wide
happens-before relation.  There are no pointer or aggregate thread arguments,
dynamic task queues, detach, cancellation, recursive traversal, filesystem
sandbox, recursive symlink policy, inotify integration, async I/O, general
worker pool, or non-Linux-x86-64 claim.  An inaccessible-path test demonstrates
the current process credentials only; it is not a privilege-boundary proof.
