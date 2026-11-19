import AppKit

@MainActor
public struct AddressSuggestionItem {
    public let title: String
    public let detail: String
    public let symbol: String
    public let isSelected: Bool
    public let menu: NSMenu?
    public let activate: () -> Void

    public init(title: String, detail: String, symbol: String, isSelected: Bool,
                menu: NSMenu?, activate: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.isSelected = isSelected
        self.menu = menu
        self.activate = activate
    }
}

/// The address panel owns its geometry. Native controls laid out by frames avoid
/// SwiftUI/AppKit window-sizing feedback during suggestion and selection changes.
public final class AddressSuggestionsView: NSVisualEffectView {
    public override var isFlipped: Bool { true }
    private var rows: [AddressSuggestionButton] = []

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true
        autoresizingMask = [.width, .height]
        setAccessibilityLabel("Address Suggestions")
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    public func setItems(_ items: [AddressSuggestionItem]) {
        rows.forEach { $0.removeFromSuperview() }
        rows = items.map(AddressSuggestionButton.init)
        rows.forEach(addSubview)
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: 6, y: 6 + CGFloat(index) * 50, width: max(0, bounds.width - 12), height: 50)
        }
    }
}

private final class AddressSuggestionButton: NSButton {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    private let item: AddressSuggestionItem
    private let nameLabel: NSTextField
    private let detailLabel: NSTextField
    private let icon = NSImageView()
    private var isHovered = false
    private var tracking: NSTrackingArea?

    init(_ item: AddressSuggestionItem) {
        self.item = item
        nameLabel = NSTextField(labelWithString: item.title)
        detailLabel = NSTextField(labelWithString: item.detail)
        super.init(frame: .zero)
        title = ""
        isBordered = false
        target = self
        action = #selector(activateSuggestion)
        menu = item.menu
        toolTip = item.detail
        setAccessibilityLabel(item.title + ", " + item.detail)
        setAccessibilitySelected(item.isSelected)
        nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        for label in [nameLabel, detailLabel] {
            label.lineBreakMode = .byTruncatingMiddle
            label.maximumNumberOfLines = 1
            label.setAccessibilityElement(false)
            addSubview(label)
        }
        nameLabel.textColor = item.isSelected ? .selectedMenuItemTextColor : .labelColor
        detailLabel.textColor = item.isSelected ? .selectedMenuItemTextColor : .secondaryLabelColor
        icon.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
        icon.contentTintColor = item.isSelected ? .selectedMenuItemTextColor : .secondaryLabelColor
        icon.setAccessibilityElement(false)
        addSubview(icon)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(_:)") }

    @objc private func activateSuggestion() { item.activate() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 10, y: 15, width: 20, height: 20)
        nameLabel.frame = NSRect(x: 40, y: 7, width: max(0, bounds.width - 50), height: 19)
        detailLabel.frame = NSRect(x: 40, y: 28, width: max(0, bounds.width - 50), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        if item.isSelected || isHovered {
            (item.isSelected ? NSColor.selectedContentBackgroundColor : NSColor.quaternaryLabelColor).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        self.tracking = tracking
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }
}
