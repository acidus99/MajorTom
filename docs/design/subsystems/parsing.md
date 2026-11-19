# Parsing

[Architecture](../architecture.md)

## Purpose and ownership

Interpret response bodies as content: Gemtext structure, plain text, source lines,
preformatted styled runs, or an image/binary payload description. Networking has
already separated protocol metadata from the body. Parsing does not make requests,
choose themes, generate HTML, or persist data.

## Boundary

Accept content metadata, byte chunks, and an explicit end or interruption. Produce
semantic content updates and diagnostics using plain data, with stable source
locations where interactions need them. Content types that require a complete body
may buffer within resource limits; text must remain incrementally consumable.

Images and unsupported binary data can remain opaque bytes plus a content
description. Parsing does not need to reimplement platform image decoders. Original
bytes remain separate and authoritative for saving and View Source.

## Guarantees

- The same response produces equivalent semantic content regardless of chunk
  boundaries, including boundaries within UTF-8, CRLF, and preformatted delimiters.
- Preserve meaningful whitespace, preformatted art, link destinations, and source
  order. Normalize only what interpretation requires, never the retained source.
- Gemtext emits headings, links, text, list items, quotations, blank lines, and
  preformatted sections. Presentation decides their visual treatment.
- ANSI SGR interpretation applies to preformatted content and resets at each line.
  It describes styled runs, not a terminal: cursor/erase/report commands have no
  executable behavior. Theme contrast adjustment belongs to Presentation.
- Capsule strings remain data. Parsing never evaluates HTML, JavaScript, exported
  SQL, or instructions embedded in content. Presentation owns output escaping.
- Completion and interruption close parser state without falsely declaring an
  incomplete response complete. Invalid text cannot crash or desynchronize the stream.

## Verification

Use small self-contained fixtures, malformed input, round-trips where applicable,
and varied byte/chunk splits. Assert semantic events and source fidelity, not
renderer markup. These tests require only the parser and supplied input.

Code landmarks: `IncrementalUTF8Decoder.swift`, `IncrementalGemtextParser.swift`,
`SourceLineSplitter.swift`, and `ANSISGR.swift` in `Sources/MajorTomCore`.
