import Foundation

/// Canonical fractional keys whose normal string ordering is their visible ordering.
public enum OrderKey {
    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    private static let indexByCharacter = Dictionary(
        uniqueKeysWithValues: alphabet.enumerated().map { ($0.element, $0.offset) }
    )
    private static let middleIndex = alphabet.count / 2
    public static let maximumLength = 64

    public static func between(
        _ lower: String?,
        _ upper: String?,
        deviceSalt: String
    ) throws -> String {
        try validate(lower)
        try validate(upper)
        if let lower, let upper, lower >= upper {
            throw OrderKeyError.invalidBounds
        }

        let base = try midpoint(lower ?? "", upper)
        let result = base + salt(for: deviceSalt)
        guard result.count <= maximumLength else { throw OrderKeyError.rebalanceRequired }
        if let lower, result <= lower { throw OrderKeyError.invalidBounds }
        if let upper, result >= upper { throw OrderKeyError.invalidBounds }
        return result
    }

    /// Evenly distributes canonical keys across the smallest useful fixed width.
    public static func initial(count: Int) -> [String] {
        guard count > 0 else { return [] }
        var width = 1
        var capacity = alphabet.count
        while capacity <= count {
            width += 1
            capacity *= alphabet.count
        }
        return (1...count).map { index in
            let value = index * capacity / (count + 1)
            return encode(value, width: width) + String(alphabet[middleIndex])
        }
    }

    private static func midpoint(_ lower: String, _ upper: String?) throws -> String {
        guard let upper else { return lower + String(alphabet[middleIndex]) }
        let lowerCharacters = Array(lower)
        let upperCharacters = Array(upper)
        var prefix = ""
        var position = 0
        while position < lowerCharacters.count,
              position < upperCharacters.count,
              lowerCharacters[position] == upperCharacters[position] {
            prefix.append(lowerCharacters[position])
            position += 1
        }

        if position == lowerCharacters.count {
            return prefix + before(String(upperCharacters.dropFirst(position)))
        }
        guard position < upperCharacters.count,
              let low = indexByCharacter[lowerCharacters[position]],
              let high = indexByCharacter[upperCharacters[position]],
              low < high else {
            throw OrderKeyError.invalidBounds
        }
        if high - low > 1 {
            return prefix + String(alphabet[low + (high - low) / 2])
        }
        let lowerRemainder = String(lowerCharacters.dropFirst(position + 1))
        return prefix + String(alphabet[low]) + lowerRemainder + String(alphabet[middleIndex])
    }

    private static func before(_ upper: String) -> String {
        var result = ""
        for character in upper {
            let high = indexByCharacter[character]!
            if high > 0 {
                result.append(alphabet[(high - 1) / 2])
                return result
            }
            result.append(alphabet[0])
        }
        // Validation prevents a canonical upper bound from ending in the minimum digit.
        preconditionFailure("Canonical upper bound has no predecessor")
    }

    private static func digit(in key: String, at position: Int) -> Int? {
        guard let character = character(in: key, at: position) else { return nil }
        return indexByCharacter[character]
    }

    private static func character(in key: String, at position: Int) -> Character? {
        guard position < key.count else { return nil }
        return key[key.index(key.startIndex, offsetBy: position)]
    }

    private static func validate(_ key: String?) throws {
        guard let key else { return }
        guard !key.isEmpty,
              key.allSatisfy({ indexByCharacter[$0] != nil }),
              key.last != alphabet[0],
              key.count <= maximumLength else {
            throw OrderKeyError.invalidKey
        }
    }

    private static func salt(for value: String) -> String {
        var accumulator: UInt64 = 1_469_598_103_934_665_603
        for byte in value.utf8 {
            accumulator ^= UInt64(byte)
            accumulator &*= 1_099_511_628_211
        }
        var characters: [Character] = []
        for _ in 0..<2 {
            characters.append(alphabet[Int(accumulator % UInt64(alphabet.count))])
            accumulator /= UInt64(alphabet.count)
        }
        // A canonical key may not end in the minimum digit.
        characters.append(alphabet[1 + Int(accumulator % UInt64(alphabet.count - 1))])
        return String(characters)
    }

    private static func encode(_ value: Int, width: Int) -> String {
        var value = value
        var result = Array(repeating: alphabet[0], count: width)
        for position in stride(from: width - 1, through: 0, by: -1) {
            result[position] = alphabet[value % alphabet.count]
            value /= alphabet.count
        }
        return String(result)
    }
}

public enum OrderKeyError: Error, Equatable, Sendable {
    case invalidBounds
    case invalidKey
    case rebalanceRequired
}
