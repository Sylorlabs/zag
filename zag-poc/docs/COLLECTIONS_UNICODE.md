# Bounded collections, iteration, and UTF-8

This Linux x86-64 slice supplies small, statically typed foundations without
claiming dynamic Python collection semantics.

- `std:hashmap` is an allocating, homogeneous `HashMap[K,V]`. It uses bounded
  linear probes, traverses deletion tombstones, updates a colliding key beyond
  a tombstone without duplicating it, and reuses the first tombstone for a new
  key. Keys and values are borrowed; the map only owns its entry table.
- `std:set` is a homogeneous `Set[K]` built on that map. The generic constructor
  requires caller-supplied hash and equality functions; `IntSet` is the bounded
  i32 convenience profile.
- `std:range` is an allocation-free, exclusive-stop `i64` range. Callers supply
  a maximum item count, and receive distinct item, exhausted, limit, and invalid
  statuses. Zero steps and negative limits fail closed. Boundary stepping never
  performs an overflowing i64 addition.
- `std:iterator` is an allocation-free generic iterator over a borrowed `[]T`.
  Its optional next value is paired with explicit exhausted, limit, and invalid
  iterator status. The backing slice must remain live and unchanged.
- `std:utf8` strictly validates and iterates Unicode scalar values and encodes a
  scalar into caller-owned storage. It rejects overlong forms, surrogates,
  out-of-range values, bad lead/continuation bytes, and truncation. Invalid
  encoding arguments do not mutate the output.

The focused gate is:

```sh
bash tests/run_collections_unicode.sh
```

It runs collision/deletion adversarial cases, allocation-balance checks, typed
set growth, range exhaustion and limits, generic slice iteration, UTF-8 boundary
and malformed corpora, a real allocation-free Script-profile consumer, static
ELF64 x86-64 inspection, a Script allocator-counter invariant, an intentional
mixed-type compile rejection with an exact typed diagnostic, and a byte-identical
rebuild from an unrelated working directory.

This slice does not claim ordered or persistent collections, automatic key/value
destruction, concurrent mutation, Unicode normalization, grapheme segmentation,
case folding, locale behavior, collation, or non-Linux target certification.
