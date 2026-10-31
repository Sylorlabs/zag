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
- `std:list.push_move[T]` moves one named affine value into the live prefix of
  a resource-valued list. It is origin-bound to the compiler-owned `std:list`
  implementation, so a same-named project helper cannot impersonate this
  transfer boundary. `std:list.insert_move[T]` opens a checked interior slot by
  backwards byte relocation and consumes one named owner into it.
  `std:list.move_all[T]` relocates the complete live prefix
  of one consumed list onto another and releases only the now-empty source
  backing allocation. `std:list.drain[T]` consumes the list, invokes a direct
  `@consumes T` drop callback for each live element, then releases the backing
  buffer. `std:list.clear_with[T]`
  invokes the same checked callback for each live element, clears the consumed
  bytes, and retains the empty backing allocation. `std:list.pop_with[T]`
  invokes that callback only for the final live element, clears that element's
  bytes, decrements `len`, and retains the backing allocation; an empty list
  fails before the callback is entered. `std:list.remove_with[T]` similarly
  consumes one checked interior element, relocates its suffix, clears the old
  final slot, and retains the backing allocation. Resource-valued `get` is a retained
  shared view only. Ordinary `push`, `set`, `pop`, `clear`, and backing-only
  `free` remain fail-closed; final destruction must visit the live prefix with
  a consuming callback, including an empty `drain` after retained-storage use.
- `std:utf8` strictly validates and iterates Unicode scalar values and encodes a
  scalar into caller-owned storage. `utf8_scalar_at` provides bounded
  allocation-free scalar-indexed lookup without confusing byte offsets with
  Unicode values. `utf8_grapheme_at` and the bounded count helpers cover the
  documented cluster seams for combining/variation marks, emoji modifiers and
  ZWJ sequences, regional-indicator pairs, Hangul composition, and CRLF;
  unknown scalars remain ordinary bases. The decoder rejects overlong forms,
  surrogates, out-of-range values, bad lead/continuation bytes, and truncation.
  Invalid encoding arguments do not mutate the output. The caller-buffer
  `utf8_normalize_nfc_bounded` helper composes a bounded common Latin subset
  (acute, grave, diaeresis, tilde, ring, and cedilla) while preserving unknown
  marks bytewise and reporting malformed, limit, and output-capacity status.

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
destruction, concurrent mutation, complete Unicode normalization beyond the
bounded common-Latin subset, complete UAX #29 grapheme segmentation or
Unicode-version property coverage, case folding, locale behavior, collation, or
non-Linux target certification.
