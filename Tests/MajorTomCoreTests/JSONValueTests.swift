import Foundation
import XCTest
@testable import MajorTomCore

final class JSONValueTests: XCTestCase {
    func testEveryCaseRoundTrips() throws {
        let values: [JSONValue] = [
            .null,
            .bool(true),
            .number(42.5),
            .string("Major Tom"),
            .array([.number(1), .string("two")]),
            .object(["value": .bool(false)]),
        ]
        for value in values {
            let data = try JSONEncoder().encode(value)
            XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), value)
        }
    }

    func testNestedObjectContainingEveryCaseRoundTrips() throws {
        let value = JSONValue.object([
            "null": .null,
            "bool": .bool(true),
            "number": .number(3.5),
            "string": .string("value"),
            "array": .array([.null, .bool(false)]),
            "object": .object(["nested": .number(7)]),
        ])
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), value)
    }

    func testSortedEncodingIsIndependentOfDictionaryConstructionOrder() throws {
        let first: JSONValue = .object(["b": .number(2), "a": .number(1)])
        let second: JSONValue = .object(["a": .number(1), "b": .number(2)])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(first), try encoder.encode(second))
    }
}
