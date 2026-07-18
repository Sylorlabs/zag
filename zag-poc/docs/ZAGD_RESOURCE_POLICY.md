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

Configuration validation accepts modes `off`, `light`, `adaptive`, and `deep`,
one to 64 workers, memory from 1 MiB through 64 GiB, cache from zero through
256 GiB, and a stability window from 1 ms through 60 seconds. Network access is
currently always rejected. The daemon blocks in inotify while idle, uses one
worker by default, applies the stability window, bounds persistent cache records,
and never uses network or GPU. Memory-budget enforcement covers planner-owned
records, not the Linux kernel's inotify accounting.

The service blocks on operating-system events while idle, cancels snapshot-bound
advice when invalidated, uses no GPU or network, and treats foreground builds as
authoritative. Deep mode remains opt-in but has no deep optimizer yet. Cache
eviction deletes cache records only, never source.

Malformed or unsupported configuration must fail closed to a diagnostic or the
documented quiet defaults. It must not silently enable workers, GPU, network, or
deep search.
