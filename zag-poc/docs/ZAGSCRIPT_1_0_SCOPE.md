# ZagScript 1.0 support boundary

The ZagScript 1.0 capability matrix is an executable contract. A row is
`supported` only when its named evidence passes and the implementation fails
closed outside the documented 1.0 boundary.

The 1.0 collection/text boundary is typed lists, string-key maps, typed sets,
bounded iterators/ranges, strict UTF-8 validation and Unicode-scalar indexing,
slicing and interpolation. Normalization and grapheme segmentation are later
text-library extensions.

The 1.0 network boundary is bounded IPv4 TCP/UDP/DNS, TLS 1.3, HTTP/1.1 and
RFC6455 WebSocket service behavior. IPv6 and HTTP/2 or HTTP/3 are later
protocol additions.

The 1.0 concurrency boundary is affine async tasks, cooperative cancellation,
bounded waits, native worker execution, SPSC channels, Linux epoll/eventfd and
Darwin kqueue/EVFILT_USER. Broader scheduler policies and MPMC channels are
later concurrency-library extensions.

The 1.0 dynamic/data boundary is the explicitly tested C ABI subset, dynamic
plugin lifecycle, memory KV and SQLite-backed services. Arbitrary ABI shapes,
arbitrary SQL APIs and hostile-plugin isolation are later extensions.

The 1.0 package boundary requires deterministic locked local/vendor packages,
an offline registry, authenticated registry metadata, deterministic version
selection, transitive module/asset locking and symlink containment. Networked
public registries are not required for 1.0.

The 1.0 optimizer boundary is bounded typed semantic-region extraction,
finite equality saturation, independently checked proof/equivalence evidence,
and sandboxed generated-candidate canary promotion with rollback. It does not
claim unbounded theorem proving or arbitrary compiler self-rewriting.

Deployment authority is platform-scoped. macOS arm64 runs its native authority
locally. Linux x86-64 runs its native and empty-PATH bootstrap authorities in
Linux, including a Linux container on an x86-64 Linux kernel. One host may not
pretend it executed a foreign native binary.

Changing a frozen capability name or widening a promised boundary requires new
executable evidence before the generated matrix can be released.
