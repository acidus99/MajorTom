# Networking

[Architecture](../architecture.md)

## Purpose and ownership

Perform requests and return responses. Networking owns connections, timeouts,
protocol limits, response framing, transport cancellation, and shared resource
scheduling. Gemini is the supported protocol; another protocol can have its own
adapter without changing Parsing or making browser code understand wire framing.

Networking interprets protocol headers/status/meta and separates them from body
bytes. It does not parse Gemtext, generate HTML, or control browser history.

## Boundary

Browser supplies a destination and request context, including cache intent and the
purpose of a resource request. Networking returns ordered progress, server identity,
response metadata, body chunks, and a terminal outcome. A response identifies its
origin (live or cached), original receipt time, and completeness. Protocol-specific
outcomes remain explicit; do not erase a Gemini input or identity challenge into a
generic success/failure abstraction.

Consult Security and Identity for server authorization and destination-scoped client
identities. Re-evaluate client identity at every redirect destination; never forward
credentials merely because the previous request used them. If approval is needed,
report a decision request through Browser and wait for UI's reply or cancellation.
Only server trust suspends a live request. Input and client-identity challenges end
the response; answering them starts another request.

Optionally consult Cache using the full request context. Replayed responses enter
the same response-handling path as live ones. Networking follows redirects under
request-purpose policy and reports hops as progress. Browser owns navigation intent,
history, and interactive outcomes, and commits only the final destination. Bound
redirect chains and detect loops, including auxiliary retrieval.

## Streaming and resource guarantees

- Metadata precedes body chunks. Exactly one terminal outcome ends the stream.
  Cancellation closes the underlying work; no late callback may revive it.
- Body chunks retain received bytes and can split UTF-8 characters or source lines.
  Networking imposes no text-line or document-structure assumptions.
- Bound response sizes and idle waits. Distinguish DNS, connection, TLS, timeout,
  malformed-response, and protocol failures using structured errors for UI wording.
- All resource paths obey trust, destination scope, redirects, cancellation, and
  applicable size limits. Downloads do not bypass security.
- Inline images use a shared queue per capsule with one transfer at a time.
  Request starts respect the configured 1–60 second interval (default two seconds).
  Fresh hits bypass the queue. Duplicate requests share work, with independent
  caller cancellation; manual activation promotes waiting work without breaking pacing.
- Gemini status 44 backs off an image queue exponentially up to 24 hours. Success
  resets backoff; cache hits do not. Cooldown survives tab navigation, while one
  capsule's delay never blocks another capsule.

## Verification

Use controlled connections to test arbitrary header/body boundaries, limits,
timeouts, trust suspension, cancellation, and terminal ordering. Use a controllable
clock for pacing/backoff, and test shared transfers with individual cancellations.
Add focused TLS/transport integration tests; live-capsule tests remain opt-in.

Code landmarks: `GeminiTransport.swift`, `GeminiResponseStreamDecoder.swift`, and
`GeminiImageLoader.swift` in `Sources/MajorTomCore`.
