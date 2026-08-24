# Linux IPv4 networking foundation

Zag's current public networking foundation is intentionally bounded. It gives
native Linux x86-64 programs resource-safe TCP and UDP IPv4 primitives plus a
DNS A-query wire codec. It is evidence for those primitives only, not for the
larger application networking stack.

## Public modules

`std:net_ipv4` exposes host-order `NetIpv4Endpoint` values and distinct
`NetTcpListener`, `NetTcpStream`, and `NetUdpSocket` resources. A successful
constructor returns `{ ok = 1, code = 0, value = ... }`; Linux syscall failures
retain their negative errno, while validation and state failures use the
documented `net_status_*` values.

Every resource contains an `open` state. Its close function invalidates the
descriptor before issuing `close(2)`, so a second close through the same value
is rejected without risking closure of a reused descriptor. The `*_take`
helpers move a successful resource out of its constructor result and invalidate
the result's copy. Until non-copyable resource types are enforced by the
language, live socket values remain linear by contract: do not copy one, and
close every successfully taken resource exactly once.

TCP send-all and receive-exact operations take explicit byte, syscall-count,
and per-syscall bounds. Their convenience forms retain a 1 MiB operation bound.
The syscall cap is also useful for deterministic testing of partial-operation
loops. UDP preserves datagram boundaries, caps payloads at the IPv4 UDP maximum,
and uses `MSG_TRUNC` so an oversized datagram is reported rather than accepted
as a silent prefix. Socket receive and send timeouts are required and limited to
1 through 60,000 milliseconds. Listener and datagram port `0` uses
`getsockname(2)` to report the kernel-selected ephemeral port.

`std:dns_ipv4` encodes one recursive A/IN query and decodes bounded A responses.
The decoder validates the complete question and resource-record envelopes,
rejects truncated packets and malformed labels/pointers, bounds packet size,
record count, and compression jumps, and detects repeated compression offsets.
Successful query packets own their byte buffer; `dns_packet_close` releases it
and rejects a second close. `dns_packet_take` provides the same explicit
move-by-convention from an encoder result as the socket take helpers.

## Executable evidence

Run:

```sh
bash tests/run_network_foundation.sh
```

The focused gate builds static Linux x86-64 binaries. The network probe binds
TCP and UDP sockets only to `127.0.0.1` on kernel-assigned ephemeral ports,
applies one-second socket timeouts, forces multi-syscall TCP send/receive loops,
checks UDP source addresses and truncation, and exercises invalid/double-close
states. It makes no external network request. The DNS probe is a local wire
corpus covering a compressed A answer plus wrong IDs, limits, truncation,
malformed labels/pointers, no-A responses, and a compression cycle. Both probes
check allocator cleanup for their owned buffers.

## Non-claims

This foundation is IPv4-only. It does not implement or certify IPv6, a system
resolver, DNS search/caching/DNSSEC/TCP fallback/IDNA, TLS, HTTP, WebSocket,
asynchronous epoll integration, cancellation, or production exposure to an
untrusted network. The automated evidence is local loopback evidence, not an
internet interoperability, security, load, or deployment certification.
