# Bounded OpenSSL 3 TLS adapter

`std:tls_openssl` is an explicit dynamic Linux x86-64 boundary for synchronous
TLS 1.3 client and server connections. Consumers must request the exact system
SONAMEs:

```sh
znc app.zag --dynamic --needed libssl.so.3 --needed libcrypto.so.3 -o app
```

Server contexts load one PEM certificate and matching private key. Client
contexts load one explicit PEM CA file, require peer verification, and bind a
checked DNS hostname with `SSL_set1_host`. Both minimum and maximum protocol
versions are fixed to TLS 1.3. Connections borrow a caller-owned connected
socket descriptor and expose bounded exact-read and write-all loops for at most
65,536 bytes and 128 OpenSSL calls. Contexts and connections use explicit
move-by-convention and one-time close operations.

Run the native reference application with:

```sh
bash tests/run_reference_tls_http_service.sh
```

The gate generates a one-day localhost certificate with a DNS SAN, builds two
byte-identical dynamic ELF64 x86-64 artifacts, requires exactly
`libssl.so.3` and `libcrypto.so.3`, and performs a verified TLS 1.3 HTTP
request/response over `127.0.0.1`. It also covers missing certificate/CA paths,
an authenticated certificate-hostname mismatch, invalid hostnames and
descriptors, move/close invalidation, exact output, allocator balance, and
refusal without explicit dynamic mode. No external network is contacted.

This adapter does not implement a static TLS stack, SNI/virtual hosting, ALPN,
HTTP/2, certificate discovery or rotation, system trust-store policy, client
certificates, CRL/OCSP, pinning, session resumption, early data, async I/O,
cancellation, load handling, or production security certification. OpenSSL's
internal allocations are outside the Zag allocator counter; explicit OpenSSL
handle cleanup is the applicable resource boundary.
