# HTTP/1.1 and WebSocket foundation

Zag's Linux x86-64 runtime includes a bounded synchronous wire and loopback
foundation for HTTP/1.1 and RFC 6455 WebSocket services:

- `std/http1.zag` encodes and parses one complete request or response with
  caller-visible limits for message, method, path, headers, and body. It
  requires strict CRLF, origin-form request paths, one non-empty `Host` request
  header, and exact `Content-Length` framing. It also exposes a bounded
  chunked-body encoder/decoder with canonical hexadecimal sizes. It also has
  bounded full-message chunked request/response encoders (including an explicit
  strict-trailer form) and an automatic body framing adapter that normalizes
  either exact Content-Length or one `Transfer-Encoding: chunked` body into an
  owned buffer. Strict trailer encode/decode helpers keep trailer fields
  separate from ordinary headers.
  Content-Length plus Transfer-Encoding, extensions, forbidden or duplicate
  trailers, and other codings fail closed.
  Parsed field slices borrow the input; encoded/decoded buffers and the
  header-view table have explicit move/close ownership. Resource take, slice,
  close, chunked-close, and header lookup helpers reject null or closed
  caller-owned handles before dereference.
- `std/http1_service.zag` receives one TCP message through
  `std/net_ipv4.zag`. Its correctness-oriented adapter reads one byte per
  bounded exact-read call so it cannot consume a following message. It is
  evidence for a safe stream boundary, not a throughput design.
- `std/websocket.zag` implements SHA-1 and canonical base64 in Zag, validates
  the RFC 6455 opening handshake, and encodes/parses complete text, binary,
  ping, pong, and close frames. Client frames are always masked; server frames
  are never masked. RSV bits, continuations/fragmentation, non-minimal lengths,
  invalid opcodes, malformed close codes, invalid UTF-8, truncation, and
  trailing bytes fail closed.

Run the focused evidence:

```sh
bash tests/run_http_websocket_foundation.sh
```

The gate executes strict negative corpora and two static native reference
services over `127.0.0.1`: one HTTP request/response and one WebSocket upgrade
plus masked-client/unmasked-server text exchange. It checks exact stdout,
descriptor double-close behavior, allocator return to baseline, static ELF64
x86-64 output, and byte-identical rebuilds of both reference applications.

## Explicit non-claims

This foundation does not provide or certify HTTP/2, HTTP/3, arbitrary transfer
codings, proxy request forms, persistent
connection routing, WebSocket fragmentation, extensions or compression,
payloads larger than 65535 bytes, async scheduling, cancellation, load
handling, denial-of-service resistance, TLS production security, or general
deployment security. It performs no external network access.
