import CoreGraphics

/// Computes the whole-item prefix shown by a Safari-style Favorites Bar.
///
/// Keeping this geometry independent of AppKit views makes window-resize behavior
/// deterministic and directly testable.
public enum FavoritesBarOverflowLayout {
    public static func requiredWidth(
        itemWidths: [CGFloat],
        horizontalInsets: CGFloat = 20,
        spacing: CGFloat = 4
    ) -> CGFloat {
        guard !itemWidths.isEmpty else { return 0 }
        return horizontalInsets
            + itemWidths.reduce(0, +)
            + CGFloat(itemWidths.count - 1) * spacing
    }

    public static func visibleItemCount(
        itemWidths: [CGFloat],
        availableWidth: CGFloat,
        leadingInset: CGFloat = 10,
        spacing: CGFloat = 4
    ) -> Int {
        var usedWidth = leadingInset
        var count = 0
        for width in itemWidths {
            let nextWidth = (count == 0 ? 0 : spacing) + width
            guard usedWidth + nextWidth <= availableWidth else { break }
            usedWidth += nextWidth
            count += 1
        }
        return count
    }

    /// Returns the index where a horizontally dragged item belongs after it is removed
    /// from its original position.
    public static func insertionIndex(
        itemWidths: [CGFloat],
        sourceIndex: Int,
        translation: CGFloat,
        leadingInset: CGFloat = 10,
        spacing: CGFloat = 4
    ) -> Int {
        guard itemWidths.indices.contains(sourceIndex) else { return sourceIndex }

        let sourceCenter = leadingInset
            + itemWidths.prefix(sourceIndex).reduce(0) { $0 + $1 + spacing }
            + itemWidths[sourceIndex] / 2
        let dropCenter = sourceCenter + translation

        var cursor = leadingInset
        var insertionIndex = 0
        for index in itemWidths.indices {
            let width = itemWidths[index]
            if index != sourceIndex, dropCenter > cursor + width / 2 {
                insertionIndex += 1
            }
            cursor += width + spacing
        }
        return min(insertionIndex, itemWidths.count - 1)
    }
}
