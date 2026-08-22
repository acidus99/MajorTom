# Major Tom Agent Guidance

## Native macOS interface first

- Use public, standard macOS controls by default for common platform concepts such as certificates, identities, files, colors, fonts, sharing, printing, search, tables, source lists, alerts, and settings.
- Before designing a custom control for a familiar macOS system concept, check the current macOS SDK and Apple developer documentation for an appropriate SwiftUI or AppKit control.
- Prefer a native SwiftUI control when one exists. When Apple provides only an AppKit control, bridge it into SwiftUI with `NSViewRepresentable` or `NSViewControllerRepresentable` instead of recreating the system interface.
- Keep custom UI for Major Tom-specific behavior that the platform control does not model, such as Gemini capsule/path certificate associations.
- Depart from a public native control only when it cannot meet the product requirement, creates a material accessibility or security problem, or is unavailable for the deployment target. Document the reason in code or the design specification.
