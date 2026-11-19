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

}
