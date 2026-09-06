import XCTest
@testable import MajorTomCore

final class OrderKeyTests: XCTestCase {
    func testUnboundedKeyUsesOnlySortableAlphabet() throws {
        let key = try OrderKey.between(nil, nil, deviceSalt: "device")
        XCTAssertFalse(key.isEmpty)
        XCTAssertTrue(key.allSatisfy { $0.isASCII && $0.isLetter || $0.isNumber })
    }

    func testGeneratedKeysAreStrictlyBetweenBounds() throws {
        let keys = OrderKey.initial(count: 100)
        for index in 0...keys.count {
            let lower = index == 0 ? nil : keys[index - 1]
            let upper = index == keys.count ? nil : keys[index]
            let key = try OrderKey.between(lower, upper, deviceSalt: "device-\(index)")
            if let lower { XCTAssertLessThan(lower, key) }
            if let upper { XCTAssertLessThan(key, upper) }
        }
    }

    func testRepeatedFrontBackAndSamePositionInsertsRemainOrderedWithRebalancing() throws {
        try exerciseRepeatedInserts(position: { _ in 0 })
        try exerciseRepeatedInserts(position: { $0 })
        try exerciseRepeatedInserts(position: { $0 / 2 })
    }

    func testInitialKeysAreStrictlyAscending() {
        let keys = OrderKey.initial(count: 1_000)
        XCTAssertEqual(keys, keys.sorted())
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertTrue(keys.allSatisfy { $0.count <= OrderKey.maximumLength })
    }

    func testRejectsInvalidBoundsAndKeys() {
        XCTAssertThrowsError(try OrderKey.between("z", "a", deviceSalt: "device"))
        XCTAssertThrowsError(try OrderKey.between("bad!", nil, deviceSalt: "device"))
        XCTAssertThrowsError(try OrderKey.between("A", "A0", deviceSalt: "device"))
    }

    private func exerciseRepeatedInserts(
        position: (Int) -> Int
    ) throws {
        var keys: [String] = []
        for index in 0..<1_000 {
            let insertion = position(keys.count)
            let lower = insertion == 0 ? nil : keys[insertion - 1]
            let upper = insertion == keys.count ? nil : keys[insertion]
            do {
                keys.insert(
                    try OrderKey.between(lower, upper, deviceSalt: "device-\(index)"),
                    at: insertion
                )
            } catch OrderKeyError.rebalanceRequired {
                keys = OrderKey.initial(count: keys.count)
                let newLower = insertion == 0 ? nil : keys[insertion - 1]
                let newUpper = insertion == keys.count ? nil : keys[insertion]
                keys.insert(
                    try OrderKey.between(newLower, newUpper, deviceSalt: "device-\(index)"),
                    at: insertion
                )
            }
            XCTAssertEqual(keys, keys.sorted())
            XCTAssertTrue(keys.allSatisfy { $0.count <= OrderKey.maximumLength })
        }
    }
}
