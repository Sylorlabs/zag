# `zagd` resource policy

Status: validated defaults enforced by the Linux daemon, 2026-07-18.

`zagd_default_config()` currently defines the intended quiet foundation:

| Setting | Default |
| --- | ---: |
| mode | light |
| workers | 1 |
| memory limit | 256 MiB |
| cache limit | 2 GiB |
| stability window | 75 ms |
| background GPU | disabled |
| network access | disabled |

Configuration accepts modes `off`, `light`, `adaptive`, and `deep`, a stability
window from 1 ms through 60 seconds, and the currently supported fixed resource
policy: one worker, a 2 GiB cache ceiling, `errors_only` notifications, no
network, and no background GPU. Unsupported worker/cache/notification values
are rejected instead of silently ignored. `script_memory_bytes` accepts 1 MiB
through 2 GiB and configures the Script requested-payload budget.
`allow_filesystem_read`, `allow_filesystem_write`, and `allow_process` accept
only `true` or `false` and are enforced by foreground Script compilation; they
are capability policy, not daemon authority. Memory
accounting excludes Linux kernel inotify storage and some compiler allocations.
The installed user service additionally enforces `MemoryMax=256M`, disables
swap for the daemon, assigns a low CPU weight, and restarts after a bounded
failure. These operating-system limits prevent advisory work from destabilizing
foreground compilation or the desktop.

The service blocks on operating-system events while idle, cancels snapshot-bound
advice when invalidated, uses no GPU or network, and treats foreground builds as
authoritative. Deep mode remains opt-in and runs only the bounded candidate and
measurement pipeline documented in the architecture; it is not an unbounded
whole-program optimizer. Cache
eviction deletes cache records only, never source.

Malformed or unsupported configuration must fail closed to a diagnostic or the
documented quiet defaults. It must not silently enable workers, GPU, network, or
deep search.

Explicit deep finalist execution uses direct `execve`, never a shell. Each child
has its own process group, CPU and address-space rlimits, a monotonic deadline,
independent 1 MiB-or-smaller stdout/stderr caps, cancellation, group kill, and
blocking reap. Eligibility additionally requires stable source/target hashes
and exact post-execution comparison with the reference stdout, stderr, exit,
signal, and state witness before timing persistence. Network, GPU, and
source-writing finalists are rejected by planner policy; filesystem writes are
not namespace-isolated, so this supervisor is not advertised as an untrusted
code sandbox and only compiler-produced reviewed finalists are eligible.
