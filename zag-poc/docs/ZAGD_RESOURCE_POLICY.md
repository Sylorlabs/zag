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
through 2 GiB and configures the Script requested-payload budget. Memory
accounting excludes Linux kernel inotify storage and some compiler allocations.

The service blocks on operating-system events while idle, cancels snapshot-bound
advice when invalidated, uses no GPU or network, and treats foreground builds as
authoritative. Deep mode remains opt-in but has no deep optimizer yet. Cache
eviction deletes cache records only, never source.

Malformed or unsupported configuration must fail closed to a diagnostic or the
documented quiet defaults. It must not silently enable workers, GPU, network, or
deep search.
