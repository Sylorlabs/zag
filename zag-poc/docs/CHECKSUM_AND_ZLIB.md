# Checksum and stored zlib primitives

Zag standard library code exposes three pure-Zag binary-format foundations:

- `checksum_crc32(bytes)` implements the reflected IEEE CRC32 used by PNG.
- `checksum_adler32(bytes)` implements the Adler32 trailer used by zlib.
- `zlib_store_encode(bytes)` writes deterministic RFC 1950 zlib streams whose
  RFC 1951 payload uses bounded uncompressed stored blocks.

`zlib_store_decode(bytes)` accepts that canonical stored-block subset and
rejects unsupported headers or block types, broken length complements,
truncation, checksum mismatches, trailing data, and output beyond the hard
256 MiB limit. Encode and decode results own their `ArrayList[u8]`; release them
with `zlib_store_encode_free` or `zlib_store_decode_free` on every path.

The stored encoder prioritizes deterministic interoperability and a small
trusted implementation over compression ratio. It does not claim general
DEFLATE decoding or dynamic/fixed Huffman support. Formats that need compact
compression may add those algorithms upstream later without changing the
validity of stored streams.

Run the focused conformance suite with:

```sh
bash tests/run_compression_primitives.sh
```

The suite covers published checksum vectors, exact interoperable zlib vectors,
empty input, block boundaries, round trips, malformed headers and blocks,
length corruption, checksum corruption, truncation, and trailing bytes.
