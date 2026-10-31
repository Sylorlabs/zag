# Package signature boundary

Zag's bounded registry index has two deliberately separate layers:

1. `signature=none` remains the ordinary offline resolver format. It binds
   canonical entry ordering and deterministic raw-byte checksums, but it is
   not an authenticity primitive.
2. `selfhost/package_signature.zag` provides an explicit detached Ed25519
   verifier for a canonical `signature=ed25519` index. It opens the index,
   public key, and signature with Linux `openat2(RESOLVE_NO_SYMLINKS)`, checks
   the signed index envelope, snapshots all three byte streams into
   create-only temporary files, and invokes the host OpenSSL provider on those
   snapshots.

The verifier returns success only for a valid 64-byte Ed25519 signature over
the exact index bytes. Mutations, wrong keys, truncated signatures, and
symlinked inputs fail closed. The focused evidence is
`tests/run_package_signature.sh` and `tests/package_signature_verify.zag`.

An opted-in local `mode = "registry"` dependency may also provide `public_key`
and `signature` paths. The resolver verifies the detached signature before
selecting an entry; `tests/run_package_signed_resolver.sh` proves valid
selection and mutation rejection. A project may additionally set
`artifact_signatures = "required"`; in that mode the selected fifth registry
entry field names a detached Ed25519 signature over the exact retained module
bytes. Missing, legacy four-field, wrong, truncated, or symlinked artifact
sidecars fail before compilation. The resolver carries the verified key,
index-signature, and artifact-signature byte snapshots into its package
resource provenance. `tests/run_package_signed_resolver.sh` covers the valid
artifact, wrong-signature, and missing-signature cases. Unsigned registry
dependencies retain the existing offline metadata mode.

This is local-index and explicitly opted-in selected-module authenticity only.
There is still no network fetch, public registry transport, complete
revision/version solver, signed policy for arbitrary package artifacts or
cache products, or broad package-policy integration. The package capability
therefore remains partial until those contracts are implemented.
