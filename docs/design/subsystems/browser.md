# Browser

[Architecture](../architecture.md)

## Purpose and ownership

Turn user intent into browser behavior. Browser contains a navigation session per
tab and focused features for bookmarks, history, settings, imports, certificates,
and browsing-data management. It is application logic, independent of SwiftUI,
AppKit, and WebKit; it is not one coordinator for every operation.

A tab owns its committed page, pending destination, active request, history cursor,
loading state, zoom, and per-visit reading state. Shared features own shared domain
state. Native windows and transient control state belong to UI; document rendering
belongs to Content Presentation; durable records belong to Data Persistence.

## Boundary

UI supplies actions such as Navigate, Rename Bookmark, or Clear Browsing Data.
Browser publishes observable state, typed failures, and requests for UI effects or
decisions. It uses focused repository interfaces and coordinates Networking, Security
and Identity, Parsing, Content Presentation, and Cache. It does not issue SQL, know
internal paths, or handle CloudKit records.

For navigation, request a response from Networking, route its body to Parsing, and
pass content updates to Presentation. Keep exact source bytes separately. Handle
protocol outcomes such as redirects, input prompts, and client-identity challenges;
Security owns authorization and Networking owns wire details. Replies carry workflow
identity so a dismissed or replaced request cannot resume a newer navigation.

## Behavior and guarantees

- Address submission distinguishes Gemini locations, searches, supported external
  URLs, and invalid explicit URLs. External links require explicit policy; UI performs
  the macOS handoff. Finder/system opens select a visible tab and coexist with restoration.
- New navigation appends after truncating the forward branch. Reload replaces the
  current visit. Back/Forward move the model cursor and prefer that visit's exact
  snapshot; absent bytes trigger retrieval without changing history structure.
  Redirects commit only their final destination. An interactive swipe commits its
  cursor only when accepted.
- Completion, interruption, and failure stay distinct. Stop cancels the tab's page
  and image work while preserving displayed content and completed images. It pauses
  automatic image submissions until a new visit; manual retries remain available.
- Successful displayable new navigations/reloads record global history. Back/Forward,
  redirect intermediates, and generated error pages do not. Ordinary input submissions
  become normal query URLs; nonsensitive unfinished drafts remain local.
- Local address suggestions use history, bookmarks, and open-tab snapshots, never
  network or per-keystroke database requests. Deduplicate destinations, preserve
  path/query case, and exclude only the current tab from Switch to Tab. Prepared
  indexes and revision checks prevent stale completion and search results.
- Data clearing stops affected work across tabs, fences late reads/writes, and leaves
  open pages displayable without retaining cleared bytes again. Persistence owns
  deletion transactions and retention policy; UI owns confirmation.
- Import validates supported Lagrange/Alhena archives before applying data. Preserve
  existing user records, never execute exported SQL, and report results by data type.

## Verification

Use controlled networking, presentation, security, repositories, and clocks. Test
ordinary and cached navigation, redirects, suspended decisions, Stop, stale results,
independent tabs, history branching, imports, and clearing during outstanding writes.
Include an integration test through Parsing and Presentation. These workflows must
be testable without a window, live server, or iCloud account.

Code landmarks: `BrowserNavigationState.swift`, `OmnibarIndex.swift`, and the bookmark
and import domain types in `Sources/MajorTomCore`.
