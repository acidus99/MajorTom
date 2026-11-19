# Security and Identity

[Architecture](../architecture.md)

## Purpose and ownership

Decide whether a server identity is acceptable and which client identity, if any,
may be offered to a destination. Own trust policy, certificate interpretation,
identity availability, user-approved capsule/path scope, and the Keychain adapter.
Data Persistence supplies repositories for trust and identity metadata.

## Boundary

Networking presents the endpoint and certificate identity for authorization and
asks for an eligible client identity. Browser invokes management operations such
as importing an identity, approving a scope, or removing trust. Return a decision,
structured failure, or a request for approval with the relevant certificate details.
Never display a dialog, choose a window, or generate localized warning text.

Trust records and client metadata use focused persistence interfaces. Private keys
stay in Keychain; pass an opaque usable identity to the TLS adapter rather than
exposing key bytes to Browser, Cache, or synchronization. Explicit user-requested
identity export is a separate operation with a UI-chosen destination.

## Policy and guarantees

- Server trust uses host, port, and SHA-256 SPKI fingerprint. First use follows the
  trust-on-first-use policy. Changed keys and invalid certificate dates
  require an explicit decision with a safe cancellation path.
- One authority owns trusted identities across tabs. Failure to read or save trust
  must not silently become first use or a successful approval. Bundled policy and
  user decisions remain distinguishable. Server trust is local to this Mac.
- Pending trust questions belong to that shared authority. Equal requests share a
  decision; a cancelling requester detaches without declining for other requesters.
  Decisions for one endpoint are serialized so competing first visits cannot
  silently establish different pins.
- Client identities are offered only within an explicitly approved destination/path
  scope. Redirects cannot expand that scope. Separate identity metadata from whether
  the actual Keychain identity is currently available.
- Client metadata may arrive before or after iCloud Keychain material. Missing keys
  mean unavailable, not deleted; remote metadata deletion never deletes a private key.
- Remove from Major Tom removes descriptors/assignments. Delete Identity Permanently
  additionally removes Keychain material after UI confirmation. Private keys never
  enter app databases, CloudKit payloads, logs, or cached responses.
- An identity decision or approval is bound to the request and account that asked
  for it. Cancellation, account changes, and replacement requests invalidate stale
  replies. Publish approval only after its durable operation succeeds.

## Verification

Test first use, matching and changed fingerprints, certificate dates, storage
failures, host/port/path matching, redirected requests, and stale approvals using
supplied certificates and controlled stores. Test unavailable Keychain material
separately from metadata removal. Use focused Keychain integration tests; signed
cross-device checks are required for actual iCloud Keychain behavior.

Code landmarks: `ServerTrustPolicy.swift`, `ClientCertificate.swift`, and
`SubjectPublicKeyFingerprint.swift` in `Sources/MajorTomCore`.
