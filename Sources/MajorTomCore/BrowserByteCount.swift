import Foundation

public enum BrowserByteCount {
    public static func formatted(_ byteCount: Int, locale: Locale = .autoupdatingCurrent) -> String {
        guard byteCount > 9_999 else {
            return ByteCountFormatStyle(
                style: .decimal, allowedUnits: .bytes, spellsOutZero: false, locale: locale
            ).format(Int64(byteCount))
        }

        let units: [UnitInformationStorage] = [
            .bytes, .kilobytes, .megabytes, .gigabytes, .terabytes, .petabytes, .exabytes
        ]
        var unitIndex = 0
        var count = Double(byteCount)
        repeat {
            count /= 1_000
            unitIndex += 1
        } while count >= 1_000 && unitIndex < units.count - 1

        // Promote a rounded 1,000 KB to 1.00 MB, and likewise for larger units.
        if count >= 999.5 && unitIndex < units.count - 1 {
            count /= 1_000
            unitIndex += 1
        }

        let result = Measurement(value: count, unit: units[unitIndex]).formatted(
            .measurement(width: .abbreviated, usage: .asProvided,
                         numberFormatStyle: .number.precision(.significantDigits(3))).locale(locale)
        )
        // Measurement uses SI's kB; Apple's file-size convention capitalizes KB.
        return result.replacingOccurrences(of: "kB", with: "KB")
    }
}
