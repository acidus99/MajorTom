import MajorTomCore

@MainActor
enum ApplicationWork {
    static let lifetime = AcceptedLocalWork()
}
