import CoreGraphics

public enum NativeWindowFrameAdjustment: String, Equatable, Sendable {
    case missingFrame
    case invalidFrame
    case belowMinimum
    case exceedsDisplay
    case movedOnscreen
}

public struct NativeWindowFrameResolution: Equatable, Sendable {
    public let frame: CGRect
    public let adjustments: [NativeWindowFrameAdjustment]

    public init(frame: CGRect, adjustments: [NativeWindowFrameAdjustment]) {
        self.frame = frame
        self.adjustments = adjustments
    }
}

/// Applies Major Tom's browser-window sizing policy independently of `NSWindow`.
///
/// Browser windows are constructed manually so SwiftUI's scene-level default size is
/// not authoritative. Keeping restoration geometry here makes malformed or obsolete
/// saved frames deterministic and directly testable.
public enum NativeWindowGeometry {
    /// The supplied reference image is 1304 × 1420 Retina pixels, or 652 × 710 points.
    public static let minimumFrameSize = CGSize(width: 652, height: 710)
    public static let defaultFrameSize = CGSize(width: 1_100, height: 760)

    public static func resolve(
        savedFrame: CGRect?,
        visibleFrames: [CGRect]
    ) -> NativeWindowFrameResolution? {
        let usableDisplays = visibleFrames.filter(isValidDisplayFrame)
        guard let firstDisplay = usableDisplays.first else { return nil }

        var adjustments: [NativeWindowFrameAdjustment] = []
        let sourceFrame: CGRect?
        if let savedFrame, isValidWindowFrame(savedFrame) {
            sourceFrame = savedFrame
        } else {
            sourceFrame = nil
            adjustments.append(savedFrame == nil ? .missingFrame : .invalidFrame)
        }

        let display = sourceFrame.map {
            closestDisplay(to: $0, among: usableDisplays)
        } ?? firstDisplay

        guard let sourceFrame else {
            let size = CGSize(
                width: min(defaultFrameSize.width, display.width),
                height: min(defaultFrameSize.height, display.height)
            )
            return NativeWindowFrameResolution(
                frame: CGRect(
                    x: display.midX - size.width / 2,
                    y: display.midY - size.height / 2,
                    width: size.width,
                    height: size.height
                ),
                adjustments: adjustments
            )
        }

        var size = sourceFrame.size
        let minimumSize = CGSize(
            width: min(minimumFrameSize.width, display.width),
            height: min(minimumFrameSize.height, display.height)
        )
        if size.width < minimumSize.width || size.height < minimumSize.height {
            size.width = max(size.width, minimumSize.width)
            size.height = max(size.height, minimumSize.height)
            adjustments.append(.belowMinimum)
        }
        if size.width > display.width || size.height > display.height {
            size.width = min(size.width, display.width)
            size.height = min(size.height, display.height)
            adjustments.append(.exceedsDisplay)
        }

        let origin = CGPoint(
            x: min(max(sourceFrame.minX, display.minX), display.maxX - size.width),
            y: min(max(sourceFrame.minY, display.minY), display.maxY - size.height)
        )
        if origin != sourceFrame.origin {
            adjustments.append(.movedOnscreen)
        }
        return NativeWindowFrameResolution(
            frame: CGRect(origin: origin, size: size),
            adjustments: adjustments
        )
    }

    private static func isValidDisplayFrame(_ frame: CGRect) -> Bool {
        isFinite(frame) && frame.width > 0 && frame.height > 0
    }

    private static func isValidWindowFrame(_ frame: CGRect) -> Bool {
        isFinite(frame) && frame.width > 0 && frame.height > 0
    }

    private static func isFinite(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.width.isFinite && frame.height.isFinite
    }

    private static func closestDisplay(to frame: CGRect, among displays: [CGRect]) -> CGRect {
        let intersecting = displays.map { display in
            (display, intersectionArea(frame, display))
        }
        if let best = intersecting.max(by: { $0.1 < $1.1 }), best.1 > 0 {
            return best.0
        }
        return displays.min { lhs, rhs in
            squaredDistance(from: frame, to: lhs) < squaredDistance(from: frame, to: rhs)
        } ?? displays[0]
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isInfinite else { return 0 }
        return intersection.width * intersection.height
    }

    private static func squaredDistance(from frame: CGRect, to display: CGRect) -> CGFloat {
        let dx = frame.midX - display.midX
        let dy = frame.midY - display.midY
        return dx * dx + dy * dy
    }
}
