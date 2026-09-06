import Foundation
import MajorTomCore
import XCTest

class FileBackedDatabaseTestCase: XCTestCase {
    private var databaseDirectories: [URL] = []

    func makeFileBackedDatabase() throws -> MajorTomDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MajorTomTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        databaseDirectories.append(directory)
        return try MajorTomDatabase(
            fileURL: directory.appendingPathComponent(MajorTomDatabase.filename)
        )
    }

    override func tearDownWithError() throws {
        for directory in databaseDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        databaseDirectories = []
        try super.tearDownWithError()
    }
}
