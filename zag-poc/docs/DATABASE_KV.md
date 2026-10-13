# Bounded database-driver contract

Zag's current database slice is a deliberately small i64 key/value contract.
It proves that a pure-Zag driver and one independently executed system SQLite
adapter can implement the same observable operations. It is not a general
database framework.

## Shared contract

`std:database_kv` defines five results: `ok`, `missing`, `invalid`, `limit`,
and `backend_error`. A database is opened with an explicit capacity from 1
through 64. The operations are `put`, `get`, `delete`, `count`, and `close`.
Keys and values are exactly signed 64-bit integers. A full database still
allows an existing key to be updated. Missing reads and deletes are reported,
and non-successful reads and counts zero their output value.

`std:database_memory` is the pure-Zag conformance driver. It allocates one
bounded slot table in Zag process memory and performs no filesystem, network,
dynamic-library, or database I/O. Closing it releases that table. Operations
after close and a second close return `invalid`.

## SQLite adapter

`std:sqlite_kv` opens only SQLite's `:memory:` name. There is no path-taking
entry point and therefore no persistence claim. Every operation uses a bounded
prepared statement, binds only i64 values, and finalizes the statement before
returning. A successful `sqlite3_close` is required before the adapter reports
a successful close; SQLite would reject that close if a statement remained
live.

The Linux x86-64 build has one explicit system dependency:

```sh
znc app.zag --dynamic --needed libsqlite3.so.0 -o app
```

The Apple-Silicon macOS build uses the target-owned SQLite import family:

```sh
znc app.zag --target macos-arm64 --dynamic -o app
```

The adapter uses the existing edition-2026 scalar/pointer `@io` foreign-call
boundary on both platforms. Linux emits dynamic ELF with the exact SONAME
`libsqlite3.so.0`; omitting either `--dynamic` or `--needed` fails before
artifact creation. macOS emits a signed ARM64 Mach-O bound only to libSystem
and `/usr/lib/libsqlite3.dylib`; `--dynamic` is required, while caller-selected
`--needed` names are rejected because audited imports select fixed system
dylibs. Neither platform selects an alternate SQLite library or bundled
fallback.

The focused evidence is:

```sh
bash tests/run_database_drivers.sh
bash tests/run_reference_sqlite_kv.sh
bash tests/run_reference_sqlite_http_service.sh
```

These gates execute invalid-capacity, missing-key, capacity-limit, update,
delete, close, post-close, and allocator-cleanup cases. They inspect Linux ELF
class/machine/interpreter plus the exact SQLite `DT_NEEDED`, or signed ARM64
Mach-O plus exactly libSystem and `/usr/lib/libsqlite3.dylib` on macOS. Runtime
output is compared byte-for-byte, no-dynamic builds must leave no artifact,
and macOS caller-selected dylib requests must fail closed.

## Bounded HTTP composition

`tests/reference_apps/sqlite_http_service/main.zag` composes the SQLite
adapter with `std:http1_service` and `std:net_ipv4`. It executes three normal
HTTP/1.1 exchanges over separate `127.0.0.1` TCP connections: `GET /kv/7`
returns the SQLite value `42`, `GET /kv/8` maps a missing database key to 404,
and `POST /kv/7` is rejected with 405. The gate checks exact responses inside
the native program, exact stdout outside it, descriptor/database double-close
behavior, Zag allocator cleanup, and byte-identical builds. Linux requires
exactly one `DT_NEEDED` entry for `libsqlite3.so.0`; macOS requires a signed
ARM64 Mach-O with exactly libSystem and `/usr/lib/libsqlite3.dylib`.

The app also injects one post-parse expectation mismatch after every per-request
owner has been acquired. The exchange must return its focused failure code,
restore the Zag allocator baseline, and leave both captured socket descriptors
at the portable raw boundary's `EBADF`; the same listener then serves all three
normal requests.

This fixture is a synchronous, fixed-route composition test. It does not turn
the bounded SQLite adapter into a general HTTP or database service.

## Deliberate limits

This slice is single-process and single-caller. It has no file-backed SQLite,
arbitrary SQL, strings, blobs, nulls, composite keys, transactions, migrations,
pooling, concurrent access, database discovery, registry protocol, or driver
plugin ABI. It provides no external traffic, production service,
authentication, request concurrency, TLS, persistence, replication, remote
database, or arbitrary-SQL behavior. The original SQLite KV reference is an
in-process native application. The HTTP composition fixture executes only four
sequential loopback exchanges: three normal route cases and one injected
cleanup negative.
