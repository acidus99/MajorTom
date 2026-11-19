import Foundation
import XCTest
@testable import MajorTomCore

final class CloudPayloadTests: XCTestCase {
    func testInvalidVersionIsRejectedAndFutureVersionIsNotDowngraded() throws {
        for version in [0, -1] {
            XCTAssertThrowsError(try CloudRecordPayload<Model>(decoding: Data("{\"name\":\"One\",\"t\":\(version)}".utf8)))
        }
        var future = try CloudRecordPayload<Model>(decoding: Data(#"{"name":"One","t":9,"future":true}"#.utf8))
        future.model.name = "Edited"
        let roundTrip = try CloudRecordPayload<Model>(decoding: future.encoded())
        XCTAssertEqual(roundTrip.storedSchemaVersion, 9)
        XCTAssertEqual(roundTrip.unknownFields["future"], .bool(true))
    }

    private struct Model: CloudSyncPayload, Equatable {
        static let payloadSchemaVersion = 1
        static let knownPayloadKeys: Set<String> = ["name", "note"]
        var name: String
        var note: String?
    }

    func testPayloadWithoutUnknownFieldsRoundTripsByteIdentically() throws {
        let data = try CloudRecordPayload(model: Model(name: "One", note: "Note")).encoded()
        let decoded = try CloudRecordPayload<Model>(decoding: data)
        XCTAssertEqual(decoded.model, Model(name: "One", note: "Note"))
        XCTAssertEqual(try decoded.encoded(), data)
    }

    func testUnknownFieldSurvivesKnownFieldMutation() throws {
        let source = Data(#"{"future":{"enabled":true},"name":"One","t":1}"#.utf8)
        var decoded = try CloudRecordPayload<Model>(decoding: source)
        decoded.model.name = "Two"
        let object = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: decoded.encoded()
        )
        XCTAssertEqual(object["name"], .string("Two"))
        XCTAssertEqual(object["future"], .object(["enabled": .bool(true)]))
    }

    func testNestedUnknownFieldsRemainByteStableAcrossEditsAndRetries() throws {
        let sources = [
            #"{"future":{"nested":{"z":2,"a":1},"values":[null,true,{"y":"Y","x":"X"}]},"t":9,"name":"One"}"#,
            #"{"name":"One","t":9,"future":{"values":[null,true,{"x":"X","y":"Y"}],"nested":{"a":1,"z":2}}}"#
        ]
        let encoded = try sources.map { source in
            var payload = try CloudRecordPayload<Model>(decoding: Data(source.utf8))
            let unknown = payload.unknownFields
            payload.model.name = "Edited"
            let bytes = try payload.encoded()
            let retried = try CloudRecordPayload<Model>(decoding: bytes)
            XCTAssertEqual(retried.unknownFields, unknown)
            XCTAssertEqual(retried.storedSchemaVersion, 9)
            XCTAssertEqual(try retried.encoded(), bytes)
            return bytes
        }
        XCTAssertEqual(encoded[0], encoded[1])
    }

    func testClearedOptionalKnownFieldIsNotRestoredAsUnknown() throws {
        let source = Data(#"{"name":"One","note":"old","t":1}"#.utf8)
        var decoded = try CloudRecordPayload<Model>(decoding: source)
        decoded.model.note = nil
        let object = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: decoded.encoded()
        )
        XCTAssertNil(object["note"])
    }

    func testMissingVersionMeansVersionOne() throws {
        let decoded = try CloudRecordPayload<Model>(
            decoding: Data(#"{"name":"One"}"#.utf8)
        )
        XCTAssertEqual(decoded.storedSchemaVersion, 1)
    }
}
