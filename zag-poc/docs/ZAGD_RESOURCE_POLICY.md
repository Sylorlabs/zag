# `zagd` resource policy

Status: validated defaults in the pure core; no running daemon yet.

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
currently always rejected. These bounds validate data only; there is no daemon
yet to allocate memory, schedule workers, evict disk records, or measure idle
resource use.

Future service code must run background work at low priority, block on operating
system events while idle, cancel obsolete work, yield to foreground builds and
tests, use no GPU outside explicit policy, and never use network access. Deep
mode remains opt-in and budgeted. Cache eviction may delete cache records only,
never source.

Malformed or unsupported configuration must fail closed to a diagnostic or the
documented quiet defaults. It must not silently enable workers, GPU, network, or
deep search.

