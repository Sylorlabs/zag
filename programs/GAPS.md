# Zag Native Backend (znc) — Gap Report

**Compiler under test:** `./znc` (native x86-64 ELF backend, `selfhost/native/`)
**Original report date:** 2026-06-29
**Last updated:** 2026-06-30 (release `2026.06.0`)

Six nontrivial programs (50–200 lines each) were compiled and run via `znc`.
Targeted micro-repros below originally confirmed each gap on the pre-release
binary.  Gaps 1–7 are **fixed**; gap 8 was informational (OK).

| Gap | Title | Severity | Status |
|-----|-------|----------|--------|
| 1 | Union scalar capture semantics | BLOCKER | **Fixed** (`3a118ed`) |
| 2 | Forward declarations SIGSEGV | BLOCKER | **Fixed** (`9fdb2b2`) |
| 3 | `@pure`/`@noalloc` vs `_zag_*` | MAJOR | **Fixed** (`3e25c27`) |
| 4 | Nested generic `ArrayList[ArrayList[T]]` | MAJOR | **Fixed** (`7433e50`) |
| 5 | `print_str` on union slice capture | MAJOR | **Fixed** (`2b580ec`) |
| 6 | i32 arithmetic truncation | MAJOR | **Fixed** (`2b580ec`) |
| 7 | `@alloc`/`@io` declaration on user fns | MINOR | **Fixed** (`8d8dd2b`) |
| 8 | Simple generic structs | INFO | OK |

Tests: `tests/run_native.sh` (111 cases) covers repros for gaps 1–6.

---

## Gap 1 — Union arm capture binds pointer-to-payload, not value

**Severity: BLOCKER** · **Status: FIXED in 2026.06.0** (`3a118ed`)

### Symptom

In the C backend (zagc), a union arm capture `|v|` binds `v` directly to the
payload value (`T`).  In the native backend (znc), `|v|` binds `v` to a
**pointer to the payload** (`*T`).  Using `v` as the value (without deref)
reads the pointer address instead of the payload, producing garbage integers
or wrong strings.

### Repro

```zag
union Expr { num: i32, neg: i32 }
fn eval(e: Expr) i32 {
    return switch (e) {
        .num => |v| v,       // WRONG in znc: v is *i32, reads pointer addr
        .neg => |v| 0 - v,
    };
}
fn main() i32 {
    let e1: Expr = Expr{ .num = 42 };
    print_i32(eval(e1));    // expected: 42 — actual: -1423573136 (garbage)
    return 0;
}
```

Compile and run:
```
$ znc /tmp/repro_union.zag -o /tmp/repro_union.out && /tmp/repro_union.out
znc: wrote native binary /tmp/repro_union.out (861 bytes main, 0 external tools)
-1423573136      # wrong — expected 42
```

Same failure with `union { i: i32, s: []u8 }` mixed-type unions.

### Root cause

`ncodegen.zag:5783–5788` (`cg_bind_capture`):
```zag
let capty: []u8 = _zag_str_concat("*", cg_norm_type(payty)); // "*i32", not "i32"
let cdisp: i32 = cg_slot_alloc_typed(env, cap, capty, 1);
push[Instr](out, i_lea(R_RAX(), R_RBP(), blk + 8));   // rax = &payload
push[Instr](out, i_store(R_RBP(), cdisp, R_RAX()));   // cap = &payload ← stores address
```

### Correct workaround (znc)

Always explicitly deref the capture:

```zag
fn eval(e: Expr) i32 {
    return switch (e) {
        .num => |vp| vp.*,       // OK: vp is *i32, vp.* is the i32 value
        .neg => |vp| 0 - vp.*,
    };
}
```

Output: `42` and `-5` as expected.

### Impact

Every existing Zag program or example using `|v| v` in union switches (e.g.,
`examples/patterns.zag`) produces wrong results when compiled with znc.
This is a **semantic incompatibility** between the two backends.

---

## Gap 2 — Forward function declarations crash znc (SIGSEGV)

**Severity: BLOCKER** · **Status: FIXED in 2026.06.0** (`9fdb2b2`)

### Symptom

A function declaration without a body (`fn foo() T;` — used as a forward
reference) causes the znc compiler process itself to segfault.

### Repro

```zag
// repro: programs/repro_fwddecl.zag
fn foo() i32;
fn main() i32 { return 0; }
```

```
$ znc programs/repro_fwddecl.zag -o /tmp/out 2>&1
Segmentation fault (core dumped)
$ echo $?
139
```

Also reproduced with the body present:
```zag
fn bar() i32;
fn foo() i32 { return bar(); }
fn bar() i32 { return 42; }
fn main() i32 { print_i32(foo()); return 0; }
```
→ same SIGSEGV in znc.

### Impact

Mutual recursion requires forward declarations; without them all functions must
be defined in dependency order.  Any reordering that would naturally place a
callee after its caller crashes the compiler.  The workaround is to always
define callees before callers (dependency-first ordering).

---

## Gap 3: @pure / @noalloc not enforced for `_zag_*` runtime calls

**Severity: MAJOR** · **Status: FIXED in 2026.06.0** (`3e25c27`)

### Symptom

The effect checker in `sema.zag` rejects obvious violations for names it knows
about (`zalloc`, `print_i32`, and similar). Call-graph proofs for `@realtime`
with `zalloc` work correctly on `znc`.

Functions annotated `@pure` or `@noalloc` that call `_zag_malloc`, `_zag_println`,
or other `_zag_*` runtime helpers are not caught today because those names are
missing from the builtin effect table. `znc` compiles them and the binary runs
the forbidden effects.

### Repro

```zag
fn bad_alloc() void @noalloc {
    let p: *i8 = _zag_malloc(8) as *i8;  // Alloc effect — forbidden by @noalloc
    _zag_free(p);
}
fn bad_io() void @pure {
    _zag_println("hello from @pure");    // IO effect — forbidden by @pure
}
fn main() i32 { bad_alloc(); bad_io(); return 0; }
```

```
$ znc /tmp/test_effects.zag -o /tmp/test_effects.out
znc: wrote native binary /tmp/test_effects.out (247 bytes main, 0 external tools)
$ /tmp/test_effects.out
hello from @pure        # violation ran unchecked
```

No error from the checker, no capability violations reported.

### Additional note

The `quicksort` function in `programs/sort_bench.zag` is annotated `@pure`
and calls `_zag_malloc` for its explicit stack — znc compiled it without
complaint.  The `@pure` annotation currently has NO enforcement in znc.

### Root cause (hypothesis)

`sema.zag:analyze()` returns an effect map, and `report_violations()` checks
it.  The znc driver (`selfhost/native/znc.zag`) calls both and aborts if
`viols > 0`.  A likely cause is that `_zag_malloc` and `_zag_println` are
not in the intrinsic-effect table consulted by `sema.zag`'s effect source
function for the native-backend runtime names, or the effect bits for those
names evaluate to 0.

---

## Gap 4 — Nested generic instantiation not supported

**Severity: MAJOR** · **Status: FIXED in 2026.06.0** (`7433e50`, one level deep)

### Symptom

Generic calls with a compound generic type as the type argument (e.g.,
`make[ArrayList[i32]]`) fail at compile time with "native: call to unknown
function".

### Repro

```zag
fn main() i32 {
    let outer: ArrayList[ArrayList[i32]] = make[ArrayList[i32]](4);
    let inner: ArrayList[i32] = make[i32](3);
    push[i32](&inner, 10);
    push[ArrayList[i32]](&outer, inner);    // fails here
    return 0;
}
```

```
$ znc /tmp/test_nested_generic.zag -o /tmp/out 2>&1
znc: error in main (line 1): native: call to unknown function
znc: error in main (line 1): native: call to unknown function
... (8 errors)
znc: build aborted — unsupported constructs (see messages above)
```

### Impact

2D data structures using `ArrayList[ArrayList[T]]` (e.g., a CSV grid, a
matrix of rows, an adjacency list) cannot be expressed via the generic
container builtins.  The workaround is to use a flat array with manual
row-stride indexing (as done in `programs/csv_parser.zag`).

---

## Gap 5 — `print_str` fails when argument is a union-arm capture

**Severity: MAJOR** · **Status: FIXED in 2026.06.0** (`2b580ec`)

### Symptom

`print_str(s)` inside a union switch arm where `s` is the bound capture
fails to compile even though `s` is declared as `[]u8`.  The native
codegen sees the capture's internal type as `*[]u8` (pointer-to-slice) and
rejects it as "not a string literal or []u8 slice".

### Repro

```zag
union MaybeStr { yes: []u8, no: i32 }
fn main() i32 {
    let v: MaybeStr = MaybeStr{ .yes = "world" };
    switch (v) {
        .yes => |s| { print_str(s); }    // compile error
        .no  => |_| { print_i32(0); }
    }
    return 0;
}
```

```
$ znc /tmp/repro_print_str_union.zag -o /tmp/out 2>&1
znc: error in main (line 5): native: print_str/println argument must be a string literal or []u8 slice
znc: build aborted — unsupported constructs (see messages above)
```

### Workaround

Load the slice explicitly from the capture pointer:
```zag
.yes => |sp| { let s: []u8 = sp.*; print_str(s); }
```
or use `_zag_println(sp.*)` which tolerates the pointer-typed argument.

---

## Gap 6 — i32 arithmetic does not truncate to 32 bits in local variables

**Severity: MAJOR** · **Status: FIXED in 2026.06.0** (`2b580ec`)

### Symptom

When an `i32` local variable holds the result of arithmetic that overflows
32 bits (e.g., a multiplication), the native backend does **not** truncate
the result to 32 bits.  The full 64-bit value remains in the 8-byte stack
slot.  `print_i32(x)` correctly reads only 32 bits, but `x as i64` reads
all 64 bits, giving a value outside the i32 range.

### Repro

```zag
fn main() i32 {
    let x: i32 = 123456789;
    x = x * 1664525 + 1013904223;  // typical LCG step, overflows 32 bits
    print_i32(x);                   // prints: 920370032 (correct 32-bit low word)
    _zag_println(_zag_i64_to_str(x as i64));  // prints: 205497925614448 (WRONG — 64-bit)
    return 0;
}
```

```
$ znc /tmp/test_lcg.zag -o /tmp/t && /tmp/t
920370032
205497925614448
```

### Additional observation

Storing an overflowed i32 to a `*i32` heap array (`arr[i] = x`) does NOT
truncate either — the full 64-bit value is written to the 8-byte slot.
Reading back via `arr[i] as i64` returns the same 64-bit value.

This caused `programs/sort_bench.zag` to sort 64-bit values (the LCG
produced 64-bit quantities) rather than 32-bit ones.  The sort still
produced correct and consistent results (both QS and MS agreed), but the
semantics differ from the expected 32-bit modular arithmetic.

### Impact

Code that relies on i32 wrapping semantics (e.g., `(a * b) as i32` giving
the low 32 bits) will produce different results in znc vs. the C backend.
Explicit masking `x & 0x7FFFFFFF` or using i64 throughout avoids the issue.

---

## Gap 7 — No explicit Alloc effect annotation syntax for user functions

**Severity: MINOR** · **Status: FIXED in 2026.07.0-dev** (`8d8dd2b`)

### Symptom

There is no user-facing annotation to declare that a function _introduces_
the Alloc effect (only `@noalloc` to forbid it).  The effect is purely
inferred by the compiler from the call graph.

### Impact

The `programs/arena.zag` task called for using "the `Alloc` effect annotation
to mark `arena_alloc`".  No such annotation exists in Zag's surface syntax.
Users can only CONSTRAIN effects (e.g., `@noalloc` says "must not allocate");
they cannot DECLARE them ("this function allocates").

### Workaround

None required — the effect is inferred automatically.  Document via comment.

---

## Gap 8 — Generic struct type parameters work (confirmed good)

**Severity: INFO (no gap)**

Generic structs with 1 or 2 type parameters compile and run correctly:

```zag
struct Box[T] { val: T }         // works
struct Pair[A, B] { first: A, second: B }  // works
```

Both instantiate correctly at `Box[i32]` and `Pair[i32, i32]`.  The gap
(Gap 4) is specifically with *compound* type arguments (`ArrayList[X]` used
as a type argument to another generic).

---

## Program Compilation Results

| Program | File | Lines | Compiled | Correct Output |
|---------|------|-------|----------|----------------|
| JSON Parser | programs/json_parser.zag | 175 | yes | yes |
| Hash Map | programs/hash_map.zag | 197 | yes | yes |
| Arena Allocator | programs/arena.zag | 130 | yes | yes |
| CSV Parser | programs/csv_parser.zag | 185 | yes | yes |
| Sort Bench | programs/sort_bench.zag | 150 | yes | yes (64-bit semantics noted) |
| State Machine | programs/state_machine.zag | 185 | yes | yes |

### Key workarounds applied (original report; several gaps now fixed)

- **json_parser.zag**: Used `struct JsonValue` with kind discriminant instead of `union JsonValue` with slice variants (Gaps 1/5 now fixed — union form would work today).
- **hash_map.zag**: Concrete `HashMap_i32` rather than `HashMap[V]` generic struct (Gap 8 confirms simple generics work).
- **arena.zag**: `arena_new` uses `@alloc`; bump-only `arena_alloc` documents no latent alloc.
- **csv_parser.zag**: Flat `*[]u8` grid indexing instead of `ArrayList[ArrayList[[]u8]]` (Gap 4 fixed for `ArrayList[ArrayList[T]]`; nested slices untested).
- **sort_bench.zag**: `quicksort` no longer carries incorrect `@pure` after Gap 3 fix; i32 LCG now wraps correctly after Gap 6 fix.
- **state_machine.zag**: Concrete `struct FSM` (not `struct FSM[S, I]`); `i32` for states/inputs for array indexing.

### Actual compiler output for each program

**json_parser.zag** (`znc programs/json_parser.zag -o programs/json_parser.out`):
```
znc: wrote native binary programs/json_parser.out (10224 bytes main, 0 external tools)
```
Output: all 4 test cases pass, key/value pairs printed correctly.

**hash_map.zag** (`znc programs/hash_map.zag -o programs/hash_map.out`):
```
znc: wrote native binary programs/hash_map.out (12111 bytes main, 0 external tools)
```
Output: 20 inserts, all lookups pass, 5 deletes confirmed, tombstone reuse pass,
post-resize lookup of 20 more pass.

**arena.zag** (`znc programs/arena.zag -o programs/arena.out`):
```
znc: wrote native binary programs/arena.out (3680 bytes main, 0 external tools)
```
Output: 1000 objects in-range, read-back correct, reset works, second-pass works.

**csv_parser.zag** (`znc programs/csv_parser.zag -o programs/csv_parser.out`):
```
znc: wrote native binary programs/csv_parser.out (7641 bytes main, 0 external tools)
```
Output: 6×4 grid parsed, quoted field "Los Angeles, CA" handled, all spot-checks pass.

**sort_bench.zag** (`znc programs/sort_bench.zag -o programs/sort_bench.out`):
```
znc: wrote native binary programs/sort_bench.out (6279 bytes main, 0 external tools)
```
Output: QS comparisons=10744, MS comparisons=8743; both sorted correctly; QS==MS pass.
Note: values are 64-bit due to i32 overflow semantics (Gap 6).

**state_machine.zag** (`znc programs/state_machine.zag -o programs/state_machine.out`):
```
znc: wrote native binary programs/state_machine.out (7528 bytes main, 0 external tools)
```
Output: traffic light cycles Red→Green→Yellow→Red correctly; tokenizer identifies
"hello", "42", "world" with correct state transitions.
