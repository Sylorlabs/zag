# `zagd` resource policy

Status: validated defaults enforced by the Linux daemon, 2026-07-24.

`planner_default_config()` and the daemon command boundary currently define the
intended product defaults:

| Setting | Default |
| --- | ---: |
| mode | adaptive |
| idle deep policy | enabled |
| difficulty | simple |
| ZagScript optimization | automatic |
| regular-Zag optimization | review |
| objective | runtime |
| trust mode | stable |
| workers | 1 |
| memory limit | 512 MiB |
| cache limit | 2 GiB |
| stability window | 75 ms |
| background GPU | disabled |
| network access | disabled |

Configuration accepts modes `off`, `light`, `adaptive`, and `deep`; the four
progressive difficulty names; explicit Script/regular optimization policies;
the stable, reviewed, and autonomous trust labels; a stability window from 1 ms
through 60 seconds; exactly one worker; a configurable cache budget from 1 MiB
through 2 GiB; default `advisory` notifications; an `errors_only` override; no
network; and no background GPU. Only `objective=runtime` is implemented.
Unsupported values and out-of-range worker/cache/notification values are
rejected instead of silently ignored. Policy acceptance does not imply that an
unavailable optimizer or verifier generation exists: those capability rows
remain fail-closed in the frozen ZagScript matrix.
`advisory` produces a normal-Zag warning only for a real supported human-review
fact; rejected planner transformations remain quiet.
`script_memory_bytes` accepts 1 MiB through 2 GiB and configures the Script
allocator budget. `allocator=script_process_arena` remains the default;
`allocator=script_bounded_heap` selects the supported per-allocation policy.
The arena charges requested payload bytes. The bounded heap charges payload
plus its 16-byte ownership header per allocation, including a zero-length
request. Other allocator names are retained as planner input but fail closed
at foreground Script compilation unless an explicit supported CLI choice
overrides them.
`max_memory_bytes` accepts 64 MiB through 2 GiB and defaults to 512 MiB. The
daemon applies it as a Linux `RLIMIT_AS` before entering the watcher loop, so
the limit also protects manually launched and per-project daemon instances
that are not supervised by systemd.
`allow_filesystem_read`, `allow_filesystem_write`, and `allow_process` accept
only `true` or `false`. `environment_allow` accepts a comma-separated exact
list of simple environment-variable names; its empty default denies Script
environment lookup. These are enforced by foreground Script compilation and
are capability policy, not daemon authority. Memory
accounting excludes Linux kernel inotify storage and some compiler allocations.
The installed user service applies `max_memory_bytes` both as `MemoryMax`
and as the daemon's `RLIMIT_AS`. Its launch runner rereads `.zagd.conf` on
every start. Use `tools/zagd-user-service.sh restart app.zag` after ordinary
policy changes; use `tools/zagd-user-service.sh reload app.zag` after changing
`max_memory_bytes`, because systemd's cgroup envelope is part of the generated
unit and needs a daemon reload. The unit path, working directory, executable,
and root-source arguments use systemd byte escapes rather than raw
interpolation. This safely supports spaces and shell-significant path bytes.
Before a service start, the launcher gives an existing compiler-auto-started
singleton a bounded graceful shutdown request and requires its project lock to
be released. The same handoff runs again at the service `ExecStart` boundary so
a foreground-start race cannot strand the unit in a singleton-exit restart
loop. A failed handoff is fail-closed; it never authorizes a second owner.

It disables swap for the daemon, assigns a low CPU weight, permits at most 64
tasks, blocks network and device namespaces, and uses `Restart=always` with a
one-second delay and a five-per-minute start limit for availability. `MemoryHigh`
is set to 90% of `MemoryMax` so the service yields before the hard cap. An OOM kill is intentionally a quiet stop
rather than a restart loop; `mode=off` is also a deliberate no-restart exit.
After resources are available or mode is re-enabled, the user or `znc watch`
may restart it. These operating-system limits prevent advisory work from
destabilizing foreground compilation or the desktop.

Every status publication includes `allocator_allocation_count`,
`allocator_live_bytes`, and `allocator_peak_live_bytes` from the native
allocator. These are logical payload-capacity witnesses used to catch retained
temporary data in the daemon itself; they are not substitutes for RSS,
`MemoryHigh`, `MemoryMax`, or `RLIMIT_AS`. The repeated-edit regression checks
both RSS and live-byte trends, then verifies that idle CPU returns to the
operating-system event wait.

The service blocks on operating-system events while idle, cancels snapshot-bound
advice when invalidated, uses no GPU or network, and treats foreground builds as
authoritative. Deep mode remains opt-in and runs only the bounded candidate and
measurement pipeline documented in the architecture; it is not an unbounded
whole-program optimizer. Cache
eviction deletes cache records only, never source.

The disk ceiling covers both `.zag-cache/zagd` advisory records and the
`.zag-cache/foreground/{machine.record,machine.code,machine.data}` triplet.
Sizes come from bounded no-follow file metadata rather than payload reads.
Non-regular or over-budget foreground entries are treated as over-limit and the
triplet is unlinked as a unit. Foreground loading independently revalidates its
own size, compiler/source graph/target/configuration identity, and payload
checksums before any codegen skip.

Malformed or unsupported project configuration fails closed to a diagnostic;
only an absent configuration file selects the documented defaults. It must not
silently enable workers, GPU, network, or deep search.

Explicit deep finalist execution uses direct `execve`, never a shell. Each child
has its own process group, CPU and address-space rlimits, a monotonic deadline,
independent 1 MiB-or-smaller stdout/stderr caps, cancellation, group kill, and
blocking reap. Eligibility additionally requires a current whole
semantic/module graph and active CPU target identity plus exact post-execution
comparison with the reference stdout, stderr, exit, signal, and state witness
before timing persistence. Network, GPU, and
source-writing finalists are rejected by planner policy; filesystem writes are
not namespace-isolated, so this supervisor is not advertised as an untrusted
code sandbox and only compiler-produced reviewed finalists are eligible.
