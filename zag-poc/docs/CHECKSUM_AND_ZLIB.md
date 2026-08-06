# Checksum, zlib, and DEFLATE primitives

Zag standard library code exposes three pure-Zag binary-format foundations:

- `checksum_crc32(bytes)` implements the reflected IEEE CRC32 used by PNG.
- `checksum_adler32(bytes)` implements the Adler32 trailer used by zlib.
- `zlib_store_encode(bytes)` writes deterministic RFC 1950 zlib streams whose
  RFC 1951 payload uses bounded uncompressed stored blocks.
- `zlib_inflate(bytes, max_output)` decodes RFC 1950 zlib streams containing
  stored, fixed-Huffman, or dynamic-Huffman RFC 1951 DEFLATE blocks.

`zlib_store_decode(bytes)` accepts that canonical stored-block subset and
rejects unsupported headers or block types, broken length complements,
truncation, checksum mismatches, trailing data, and output beyond the hard
256 MiB limit. Encode and decode results own their `ArrayList[u8]`; release them
with `zlib_store_encode_free` or `zlib_store_decode_free` on every path.

The general inflater validates the RFC 1950 header, rejects preset dictionaries,
builds canonical bounded Huffman tables, supports overlapping back-references,
requires an end-of-block code, verifies the Adler32 trailer, and rejects
trailing bytes. The caller supplies a positive output ceiling no larger than
256 MiB so compressed input cannot silently expand beyond its policy. Its
result owns its byte list and must be released with `zlib_inflate_free` on
success and failure paths.

The stored encoder remains the deterministic output primitive. It prioritizes
interoperability and a small trusted implementation over compression ratio;
general inflate support does not change the canonical bytes it produces.

Run the focused conformance suite with:

```sh
bash tests/run_compression_primitives.sh
bash tests/run_zlib_inflate.sh
bash tests/run_zlib_inflate_arm64.sh
```

The suites cover published checksum vectors, exact interoperable zlib vectors,
stored/fixed/dynamic and mixed blocks, empty input, block boundaries, overlapping
matches, bounded expansion, malformed headers and blocks, length and checksum
corruption, every strict prefix of a dynamic stream, single-bit mutations, and
trailing bytes. The fixed, dynamic, and mixed-block fixtures are independently
produced by Python zlib; Python is not a Zag runtime or build dependency.
The ARM64 gate compiles the same strict source through Zag's AArch64 backend
and executes it with qemu-user, including binary `\\xNN` string literals used
by the independent interoperability fixtures.
