# Linux x86-64 features

Status: implemented target-permission foundation, 2026-07-24.

The native target is Linux ELF64 x86-64. The implemented profile resolver
defines `generic`, `x86-64`, and `x86-64-v1` as aliases for one canonical
`x86-64-v1` cache identity. That baseline advertises SSE2 only. Existing
scalar integer and scalar SSE2 floating-point encoding is the supported
foundation; this table is about target selection, not every instruction present
in the encoder.

| Feature/profile | Current status |
| --- | --- |
| `generic` | implemented; canonicalizes to `x86-64-v1` |
| `x86-64`, `x86-64-v1` | implemented aliases |
| SSE2 | advertised by the generic profile; scalar floating point and baseline MOVDQU memcpy chunks |
| SSE3, SSSE3, SSE4.1, SSE4.2 | not advertised |
| baseline scalar byte swap | `byte_swap64(i64)` lowers to `BSWAP r64`; fixed x86-64 instruction, not SIMD |
| baseline scalar leading-zero count | `leading_zeros(i64)` guards zero then lowers nonzero input to `BSR r64`; fixed x86-64 instruction, not SIMD |
| POPCNT | generic fallback; native-gated opcode; cached dispatch with `--cpu=runtime` |
| AVX, AVX2, FMA, BMI1, BMI2, AVX-512 | not advertised |
| `native` | CPUID/OS-gated SSE2 plus POPCNT when present and tested |
| runtime multiversioning | `popcount(i64)`, BMI1 `andn(i64,i64)`, and BMI1 `trailing_zeros(i64)` intrinsics |
| i686 / ELF32 | executable/relocatable i32 and SysV x87 f32/f64 subset |

Native resolution executes CPUID directly. AVX usability requires the CPU AVX
bit, OSXSAVE, and XGETBV confirmation that XCR0 enables both XMM and YMM state;
AVX2 additionally requires its leaf-7 bit. Deterministic negative tests prove
that hardware AVX alone and OSXSAVE without YMM state remain disabled. The
compiler then intersects detected features with its independently tested
encoder permission set. That permitted set is
currently SSE2 (including compiler-owned unaligned MOVDQU bulk-copy chunks) plus separately gated POPCNT lowering. Detecting AVX, AVX2, FMA,
BMI or AVX-512 never enables their emission.

The planner follows the same permission boundary. Exact-key profile samples may
be retained as checksum-bound, declaration-validated advisory evidence for
`popcount` and `andn`; the current daemon records its generic target identity
and never changes a foreground compiler target or instruction stream. A row is
eligible only when its exact current compiler image, parsed module contents,
semantic declaration/graph, and target permission remain valid. The foreground
compiler consumes that evidence only as bounded metadata with
`codegen_effect=none`; `znc suggest` still marks it non-automatic and
unsupported because no declaration-to-machine-region map exists for safe PGO
rewrites. `simd-packed` is an explicit unsupported record, not an instruction
selection request; no user-requested packed SSE/AVX code is emitted from
profile evidence. The compiler-owned memcpy runtime does use SSE2 MOVDQU
chunks, which is a fixed semantics-preserving baseline implementation rather
than planner selected vectorization.

The profile module emits a stable JSON report and a target-qualified cache key.
`znc --cpu generic` and `znc --cpu native` are CLI-integrated. The target-policy
gate executes integer and floating ABI paths under each and requires
equivalent observable output. `popcount(i64)` uses a baseline software sequence
for `generic`, a POPCNT opcode only when `native` detects and permits it, and a
cached CPUID-selected generic/POPCNT path for `runtime`. This narrow dispatch is
not general function multiversioning. `andn(a,b)` has the exact generic fallback
`(~a) & b`. `trailing_zeros(i64)` returns 64 for zero and otherwise the exact
count of trailing zero bits; it uses BMI1 TZCNT only under the same
native/runtime permission, with a generic shift loop. Native emission requires
CPUID leaf 7 EBX bit 3. Runtime mode caches that decision independently from
POPCNT and never executes BMI1 paths when BMI1 is absent. BMI1 does not require
extended OS register state;
AVX-family dispatch still requires OSXSAVE and XCR0 XMM/YMM qualification.
Linux x86-64 support must not be described as full x86-family support until the
separate i686 milestone passes.

`--target i686`, `--target x86`, and `--target linux-i686` select an isolated
ELF32 milestone backend. It accepts a non-generic `i32 main` with initialized
`i32` locals and parameters, assignment, integer constants, arithmetic,
comparisons, structured branches/loops, non-generic `i32` calls, and scalar
`f32`/`f64` locals, arithmetic, comparison, width-correct stack arguments, and
ST(0) returns. These nodes
lower through a validated integer IR into i386 frames with caller-cleaned stack
arguments and EAX returns; Linux startup exits through `int 0x80`. Unsupported
types and AST nodes reject before output. This is executable i386-backend
proof, not general i686 language support.

The same isolated backend represents `i64`/`u64` as two little-endian 32-bit
limbs. It covers range-checked literals, locals, assignment, casts, add/subtract
with carry, wrapping multiplication, deterministic 64-step signed/unsigned
division and remainder, bitwise AND/OR/XOR, signed and unsigned comparisons,
logical/arithmetic shifts, two-word cdecl arguments, EDX:EAX returns,
sequential struct leaves, and hidden-sret publication across separately emitted
objects. Zero divisors report the same status-134 panic as 32-bit division;
`INT64_MIN/-1` wraps and its remainder is zero.

Signed i32 arithmetic includes wrapping multiplication plus defined division
and remainder. Zero divisors report `panic: division by zero` and exit 134;
the `INT_MIN/-1` quotient and remainder edges are handled without allowing the
hardware `idiv` overflow trap to define language behavior.

The milestone defines `usize` and supported pointers as 32-bit ABI words.
`usize` has unsigned ordering and unsigned division/remainder across its complete
`0..0xffffffff` range; arithmetic wraps at 32 bits. Explicit `i32`/`usize`
casts preserve the low word, mixed variables require a cast, and out-of-range
integer literals reject instead of truncating. Address-of is restricted to
initialized stack locals; dereference and indirect store support `*i32` and
`*usize`. Pointer indexing uses a four-byte stride and checks 32-bit address
overflow, while general pointer arithmetic and pointer/integer casts reject.
Byte-slice indexing checks its unsigned index against the 32-bit length and
traps deterministically on negative or high-bit out-of-bounds indices.
Fixed-size arrays remain unsupported by the v1 language.

The scalar cdecl subset also carries `i8`, `u8`, `i16`, `u16`, and `bool` in
four-byte argument words and EAX. Signed values are sign-extended; unsigned
values are zero-extended; booleans are canonicalized to zero or one. The
compiler normalizes caller arguments, callee parameter loads, narrow local
stores, callee returns, and post-call results. Explicit narrowing casts retain
the low destination bits, while a directly contextual literal must fit. This
does not alter the packed one-byte representation of `*u8` or `[]u8`.

The same value rules apply to sequential structs through a compiler-defined
four-byte word slot per narrow leaf. Acyclic child structs recursively inline
their checked layout. Narrow field initialization, nested assignment/load,
matching local/sub-struct copies, cdecl argument words, parameter views, and
hidden-sret publication/consumption are normalized. The focused multi-object
gate executes all five narrow field kinds across separately emitted ELF32
objects. Direct/mutual by-value cycles, unions, packed/bitfield layouts, and
aggregate mutation through by-value parameters remain fail-closed.

`f32`/`f64` and `i64`/`u64` aggregate leaves use the SysV i386 four-byte
alignment rule. `f32` occupies one word and each 64-bit leaf occupies two
adjacent little-endian words; recursive
field offsets and final sizes therefore remain multiples of four without an
invented eight-byte `f64` alignment hole. Nested field operations, aggregate
copies, reverse-order cdecl arguments, parameter reads, and hidden-sret
production/consumption preserve those words. Separate-object execution fixtures
cover `f64` at offset 4 in a 20-byte mixed struct and a three-level, 48-byte
sequential struct containing every supported scalar category.

The subset also covers basic local scalar structs, signed i32 output, scalar
`!i32`, ELF32 symbols/debug-line metadata, relocatable objects, deterministic
archives, and pure-Zag multi-object/archive linking with local, strong, then
weak-symbol resolution plus `R_386_32` and `R_386_PC32`.
Compiler-produced objects can define/export supported `pub` functions and
reference supported external functions through `R_386_PC32`; the focused test
suite links two such objects and executes the result. `SHN_ABS` symbols use
their absolute values for both supported relocation formulas. Malformed symbol
section indices, section-escaping symbol values/sizes, and unknown relocation
kinds reject during input preflight.
The pure-Zag linker emits page-separated RX text and RW data load segments.
It supports bounded `SHN_COMMON` declarations with global or weak binding:
their power-of-two `st_value` alignment is capped at 4096 bytes, their nonzero
`st_size` allocation is capped by the 64 MiB image limit, and same-name included
declarations merge to the largest size and alignment as zero-filled RW storage.
An included regular strong definition overrides COMMON; a direct/included strong
COMMON satisfies normal archive demand in archive order, while weak COMMON never
pulls an archive member. COMDAT, TLS, dynamic linking, heap ownership, and
complete i386 ABI/runtime support remain outside this milestone. Weak support is
otherwise limited to deterministic ELF32 static resolution: strong definitions
override weak ones, weak archive members never satisfy demand extraction, and
unresolved weak references use `S = 0` for the two supported relocation kinds.

The executable i686 subset includes merged source imports, escaped byte-string
literals, and explicit mmap2/munmap-backed `_zag_malloc`/`_zag_free` for the
supported 32-bit pointer types. It deliberately does not infer ownership,
reclaim leaked allocations, provide realloc, or expose a general allocator ABI.

Its small-register policy is explicit: EAX/ECX/EDX are scratch, EBP anchors a
4-byte-aligned frame, and expression temporaries use stack spill slots rather
than pretending the x86-64 register allocator applies unchanged. Local spill
frames are bounded to 1 MiB and pushed call arguments to 64 KiB before output.
`tests/run_i686_release_gate.sh` is the authority for this boundary. It runs the
runtime and multi-object suites with optional host compiler/linker inspection
disabled, executes through native Linux i386 compatibility or `qemu-i386`, and
adds compiler/target identity plus artifact-negative 64 KiB call-area and
1 MiB frame-limit cases. This proves the stated subset only; it does not
promote i686 to equal language/public-C-ABI, dynamic/TLS, or external
distribution parity with the x86-64 backend.
