# UI

[Architecture](../architecture.md)

## Purpose and ownership

Provide the native Mac experience: windows, native tabs and Tab Overview, menus,
commands, address editing, managers, Settings, accessibility, and system integration.
UI owns focus, selection, transient editing state, localized wording, and every
dialog, sheet, panel, and confirmation. Content Presentation owns the document surface.

Use public SwiftUI controls first and narrow AppKit bridges where necessary. Follow
Apple terminology: Settings, link, Title Case commands, and an ellipsis on commands
that require further input. Document themes are independent of application appearance.

## Boundary

UI observes focused application models and calls their intent methods. Those models
hide repositories, CloudKit, network transports, and trust storage. Operations that
span several models use a workflow coordinator; simple edits need no forwarding
controller. UI owns controls and transient editing state, not domain records.

UI hosts Content Presentation and supplies native appearance, viewport, and chrome
geometry. Presentation reports document interactions to Browser. UI carries out
native effects requested by Browser, such as choosing a save destination, opening
another window, revealing a file, or handing an external URL to macOS. A selected
file URL is a permission-bearing destination, not knowledge of internal storage paths.

Commands from menus, toolbars, keyboard shortcuts, gestures, and context menus reach
the same feature action. Keyboard focus and editing remain native. Destructive
confirmations explain scope, use destructive styling, and default to Cancel.

## Native control constraints

- AppKit owns native tab groups and Tab Overview. The tab track remains full-width,
  including throughout overview animations. Its Add Tab slot is removed without
  resizing the tab bar; New Tab remains available through File and Command-T.
  Show Tab Overview follows Reload/Stop; its nonactivating exit control and Escape
  return to the selected tab. Native-view discovery must not invoke private selectors.
- Navigation uses SwiftUI Liquid Glass. Connected Back/Forward and Home/Page
  Information groups use compact independent actions in glass containers because
  there is no suitable public connected-pill control. Preserve native interaction,
  focus, and accessibility rather than drawing substitute controls.
- The address field retains the AppKit field editor for selection, Undo, input
  methods, and inline-completion suffix selection. Its nonactivating suggestion
  panel uses AppKit-owned geometry: mixing SwiftUI layout into that transient panel
  causes recursive layout invalidation. Dismiss on focus loss or deactivation.
- Restore complete window groups before presenting them; never flash a default
  homepage window first. New windows cascade from the active window. Enforce the
  652 × 710 point minimum and repair saved frames against connected displays.
- Native Back/Forward swipes use Browser's history, not WebKit's retained page list.
  One physical swipe traverses at most one entry. Command-Option-Up and
  Command-Option-Shift-Up navigate upward; Command-Up/Down retain document scrolling.

## Verification

Test command routing, native tab selection and restoration, focus and input methods,
VoiceOver labels/state, and destructive cancellation. Verify light/dark application
appearance independently of content themes. Use focused AppKit/WebKit tests and
manual native checks; substitute Browser state/actions for UI-only tests.

Code landmarks: `MajorTomApp.swift`, `OmnibarAddressField.swift`, and
`Sources/MajorTomAppKitSupport`. The [build guide](../how-to-build.md) covers app builds.
