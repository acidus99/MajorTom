import AppKit
import AudioToolbox
import MajorTomCore
import SwiftUI

/// Owns the single About window.
///
/// Built as an `NSWindow` around the SwiftUI view rather than as a `Window` scene so it
/// can be opened from the application delegate, which has no `openWindow` action, and so
/// it stays out of the Window menu and out of session restoration.
///
/// State lives here rather than on the delegate so the notification observer that calls
/// `show()` captures nothing: sending a non-`Sendable` delegate into that closure is a
/// data race the compiler correctly refuses.
@MainActor
enum AboutWindowPresenter {
    private static var window: NSWindow?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let created = NSWindow(contentViewController: NSHostingController(rootView: AboutView()))
        created.title = "About Major Tom"
        created.styleMask = [.titled, .closable]
        // The window outlives this call; without this it is deallocated on close and the
        // next About would reach a freed object.
        created.isReleasedWhenClosed = false
        created.center()
        created.makeKeyAndOrderFront(nil)
        window = created
    }
}

/// The About panel, following the legacy app's layout: a large app icon, the name, the
/// version, and the copyright, centred in a fixed-width column.
///
/// The version is shown in the commit-date scheme rather than a hand-maintained semantic
/// version — `2026.8.4 (231)` — with the full build identity beneath it. That second line
/// is the one worth quoting in a bug report, so it is selectable and monospaced.
struct AboutView: View {
    @State private var midiPlayer = AboutMIDILooper()
    @State private var isMIDIPlaying = false
    @State private var isIconHovered = false
    @State private var playbackError: String?

    var body: some View {
        VStack(spacing: 16) {
            Button {
                do {
                    isMIDIPlaying = try midiPlayer.toggle()
                } catch {
                    isMIDIPlaying = false
                    playbackError = error.localizedDescription
                }
            } label: {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 128, height: 128)
                    .overlay(alignment: .bottomTrailing) {
                        if isMIDIPlaying || isIconHovered {
                            Image(systemName: isMIDIPlaying ? "stop.circle.fill" : "play.circle.fill")
                                .font(.system(size: 25))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .padding(3)
                                .transition(.opacity.combined(with: .scale(scale: 0.85)))
                        }
                    }
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    isIconHovered = hovering
                }
            }
            .help(isMIDIPlaying ? "Stop MIDI" : "Play MIDI")
            .accessibilityLabel(isMIDIPlaying ? "Stop Major Tom MIDI" : "Play Major Tom MIDI")

            Text("Major Tom")
                .font(.system(size: 28, weight: .semibold))

            VStack(spacing: 5) {
                Text("Version \(AppVersion.short) (\(AppVersion.build))")
                    .font(.system(size: 15))
                Text(AppVersion.buildInfo)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
            }
            .accessibilityElement(children: .combine)

            Text("A native macOS browser for Gemini.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("Copyright \u{00A9} 2026 Major Tom\nAll rights reserved.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .padding(.top, 26)
        .padding(.bottom, 30)
        .frame(width: 420)
        .onDisappear {
            midiPlayer.stop()
            isMIDIPlaying = false
        }
        .alert(
            "MIDI Playback Failed",
            isPresented: Binding(
                get: { playbackError != nil },
                set: { if !$0 { playbackError = nil } }
            )
        ) {
            Button("OK") {
                playbackError = nil
            }
        } message: {
            Text(playbackError ?? "Unknown error")
        }
    }
}

/// Plays the bundled Standard MIDI file through macOS's built-in General MIDI synth.
///
/// `AVMIDIPlayer` requires a separate sound bank on macOS. A `MusicSequence`, on the
/// other hand, supplies a system GM/GS synth when no custom audio graph is assigned,
/// keeping the easter egg self-contained and tiny.
@MainActor
private final class AboutMIDILooper {
    private var sequence: MusicSequence?
    private var player: MusicPlayer?

    func toggle() throws -> Bool {
        if isPlaying {
            stop()
            return false
        }

        try start()
        return true
    }

    func stop() {
        guard let player else { return }
        MusicPlayerStop(player)
        MusicPlayerSetTime(player, 0)
    }

    private var isPlaying: Bool {
        guard let player else { return false }
        var playing = DarwinBoolean(false)
        guard MusicPlayerIsPlaying(player, &playing) == noErr else { return false }
        return playing.boolValue
    }

    private func start() throws {
        if player == nil {
            try prepare()
        }

        guard let player else {
            throw MIDIPlaybackError.playerUnavailable
        }

        try check(MusicPlayerSetTime(player, 0), operation: "rewind")
        try check(MusicPlayerPreroll(player), operation: "prepare audio")
        try check(MusicPlayerStart(player), operation: "start playback")
    }

    private func prepare() throws {
        guard let midiURL = Bundle.module.url(forResource: "major-tom", withExtension: "mid") else {
            throw MIDIPlaybackError.missingResource
        }

        var newSequence: MusicSequence?
        try check(NewMusicSequence(&newSequence), operation: "create sequence")
        guard let newSequence else {
            throw MIDIPlaybackError.sequenceUnavailable
        }

        do {
            try check(
                MusicSequenceFileLoad(newSequence, midiURL as CFURL, .midiType, []),
                operation: "load MIDI"
            )
            try makeSequenceLoopForever(newSequence)

            var newPlayer: MusicPlayer?
            try check(NewMusicPlayer(&newPlayer), operation: "create player")
            guard let newPlayer else {
                throw MIDIPlaybackError.playerUnavailable
            }

            do {
                try check(
                    MusicPlayerSetSequence(newPlayer, newSequence),
                    operation: "connect sequence"
                )
            } catch {
                DisposeMusicPlayer(newPlayer)
                throw error
            }

            sequence = newSequence
            player = newPlayer
        } catch {
            DisposeMusicSequence(newSequence)
            throw error
        }
    }

    private func makeSequenceLoopForever(_ sequence: MusicSequence) throws {
        var trackCount: UInt32 = 0
        try check(
            MusicSequenceGetTrackCount(sequence, &trackCount),
            operation: "read track count"
        )

        var tracks: [MusicTrack] = []
        var loopDuration: MusicTimeStamp = 0

        for index in 0..<trackCount {
            var track: MusicTrack?
            try check(
                MusicSequenceGetIndTrack(sequence, index, &track),
                operation: "read track"
            )
            guard let track else { continue }

            var trackLength: MusicTimeStamp = 0
            var propertySize = UInt32(MemoryLayout<MusicTimeStamp>.size)
            try check(
                MusicTrackGetProperty(
                    track,
                    kSequenceTrackProperty_TrackLength,
                    &trackLength,
                    &propertySize
                ),
                operation: "read track length"
            )
            tracks.append(track)
            loopDuration = max(loopDuration, trackLength)
        }

        guard loopDuration > 0 else {
            throw MIDIPlaybackError.emptySequence
        }

        var tempoTrack: MusicTrack?
        try check(
            MusicSequenceGetTempoTrack(sequence, &tempoTrack),
            operation: "read tempo track"
        )
        if let tempoTrack {
            tracks.append(tempoTrack)
        }

        for track in tracks {
            var trackLength = loopDuration
            try check(
                MusicTrackSetProperty(
                    track,
                    kSequenceTrackProperty_TrackLength,
                    &trackLength,
                    UInt32(MemoryLayout<MusicTimeStamp>.size)
                ),
                operation: "align track length"
            )

            var loopInfo = MusicTrackLoopInfo(
                loopDuration: loopDuration,
                numberOfLoops: 0
            )
            try check(
                MusicTrackSetProperty(
                    track,
                    kSequenceTrackProperty_LoopInfo,
                    &loopInfo,
                    UInt32(MemoryLayout<MusicTrackLoopInfo>.size)
                ),
                operation: "enable looping"
            )
        }
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw MIDIPlaybackError.audioToolbox(operation: operation, status: status)
        }
    }
}

private enum MIDIPlaybackError: LocalizedError {
    case missingResource
    case sequenceUnavailable
    case playerUnavailable
    case emptySequence
    case audioToolbox(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingResource:
            "The bundled MIDI file could not be found."
        case .sequenceUnavailable:
            "macOS could not create a MIDI sequence."
        case .playerUnavailable:
            "macOS could not create a MIDI player."
        case .emptySequence:
            "The MIDI file contains no playable music."
        case let .audioToolbox(operation, status):
            "Could not \(operation) (AudioToolbox error \(status))."
        }
    }
}
