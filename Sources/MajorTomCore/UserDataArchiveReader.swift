import Foundation

public enum LagrangeArchiveReader {
    public static func read(_ url: URL) throws -> LagrangeUserDataExport {
        let names = try ArchiveReader.output(arguments: ["-Z1", url.path]).split(whereSeparator: \.isNewline).map(String.init)
        let wanted = names.filter { name in
            name == "lagrange-export.ini" || name == "bookmarks.ini" || name == "sitespec.ini"
                || name == "trusted.txt" || (name.hasPrefix("idents/") && (name.hasSuffix(".crt") || name.hasSuffix(".key")))
        }
        var files: [String: Data] = [:]
        for name in wanted {
            files[name] = try ArchiveReader.data(arguments: ["-p", url.path, name])
        }
        return try LagrangeUserDataExport(files: files)
    }
}

/// Reads only Alhena's two documented export members and never executes script.sql.
public enum AlhenaArchiveReader {
    public static func read(_ url: URL) throws -> AlhenaUserDataExport {
        let names = try ArchiveReader.output(arguments: ["-Z1", url.path])
            .split(whereSeparator: \.isNewline).map(String.init)
        var files: [String: Data] = [:]
        for name in ["version.txt", "script.sql"] where names.contains(name) {
            files[name] = try ArchiveReader.data(arguments: ["-p", url.path, name])
        }
        return try AlhenaUserDataExport(files: files)
    }
}

private enum ArchiveReader {
    static func output(arguments: [String]) throws -> String {
        String(data: try ArchiveReader.data(arguments: arguments), encoding: .utf8) ?? ""
    }

    static func data(arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
        return output
    }
}

