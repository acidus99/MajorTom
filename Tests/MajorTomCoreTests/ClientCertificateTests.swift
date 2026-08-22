import Foundation
import XCTest
@testable import MajorTomCore

final class ClientCertificateTests: XCTestCase {
    private let root = URL(string: "gemini://example.com/")!

    func testEntireCapsuleIncludesEveryPathButNotAnotherPort() throws {
        let association = ClientCertificateAssociation.entireCapsule(
            certificateID: UUID(),
            endpoint: CapsuleEndpoint(host: "example.com")
        )

        XCTAssertTrue(association.matches(root))
        XCTAssertTrue(association.matches(URL(string: "gemini://example.com/a/b?ignored")!))
        XCTAssertFalse(association.matches(URL(string: "gemini://example.com:1966/a/b")!))
        XCTAssertFalse(association.matches(URL(string: "gemini://other.example/a/b")!))
    }

    func testPathScopeUsesPathBoundariesAndIgnoresQuery() throws {
        let association = try XCTUnwrap(ClientCertificateAssociation.pathAndDescendants(
            certificateID: UUID(),
            url: URL(string: "gemini://example.com/private?register")!
        ))

        XCTAssertTrue(association.matches(URL(string: "gemini://example.com/private")!))
        XCTAssertTrue(association.matches(URL(string: "gemini://example.com/private/child?q")!))
        XCTAssertFalse(association.matches(URL(string: "gemini://example.com/privateer")!))
        XCTAssertFalse(association.matches(root))
    }

    func testMostSpecificAssociationWins() throws {
        let rootAssociation = ClientCertificateAssociation.entireCapsule(
            certificateID: UUID(), endpoint: CapsuleEndpoint(host: "example.com")
        )
        let privateAssociation = try XCTUnwrap(ClientCertificateAssociation.pathAndDescendants(
            certificateID: UUID(), url: URL(string: "gemini://example.com/private/")!
        ))

        XCTAssertEqual(
            ClientCertificateAssociation.mostSpecific(
                matching: URL(string: "gemini://example.com/private/page")!,
                in: [rootAssociation, privateAssociation]
            ),
            privateAssociation
        )
    }

    func testAuthenticationDefaultsToTheWholeCapsule() {
        XCTAssertEqual(
            ClientCertificateScopeChoice.authenticationDefault,
            .entireCapsule
        )
    }

    func testStationJoinPathScopeDoesNotLogInSiblingRoutesButCapsuleScopeDoes() throws {
        let certificateID = UUID()
        let join = URL(string: "gemini://station.martinrue.com/join")!
        let timeline = URL(string: "gemini://station.martinrue.com/timeline")!
        let root = URL(string: "gemini://station.martinrue.com/")!
        let joinOnly = try XCTUnwrap(ClientCertificateAssociation.pathAndDescendants(
            certificateID: certificateID,
            url: join
        ))
        let wholeStation = ClientCertificateAssociation.entireCapsule(
            certificateID: certificateID,
            endpoint: CapsuleEndpoint(host: "station.martinrue.com")
        )

        XCTAssertTrue(joinOnly.matches(join))
        XCTAssertFalse(joinOnly.matches(timeline))
        XCTAssertFalse(joinOnly.matches(root))
        XCTAssertTrue(wholeStation.matches(join))
        XCTAssertTrue(wholeStation.matches(timeline))
        XCTAssertTrue(wholeStation.matches(root))
    }

    func testChangingScopeRetainsTheApprovedURLBoundary() {
        var association = ClientCertificateAssociation.entireCapsule(
            certificateID: UUID(),
            endpoint: CapsuleEndpoint(host: "station.martinrue.com"),
            approvedPath: "/join"
        )

        XCTAssertTrue(association.matches(URL(string: "gemini://station.martinrue.com/")!))
        XCTAssertEqual(association.pathPrefix, "/join")

        association.scope = .pathAndDescendants
        XCTAssertTrue(association.matches(URL(string: "gemini://station.martinrue.com/join/profile")!))
        XCTAssertFalse(association.matches(URL(string: "gemini://station.martinrue.com/timeline")!))
    }
}
