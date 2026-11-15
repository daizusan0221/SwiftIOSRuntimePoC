import Foundation
import UIKit

enum RunCSV {
    static func directory(_ name: String) throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true)
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func files(_ folder: String) -> [URL] {
        guard let directory = try? directory(folder),
              let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return entries.filter { $0.pathExtension == "csv" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static func create(in folder: String, timestamp: String, header: String) throws -> URL {
        let name = timestamp.replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString.prefix(8) + ".csv"
        let url = try directory(folder).appendingPathComponent(name)
        try Data((header + "\r\n").utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }

    static func append(_ values: [String], to url: URL) throws {
        let line = values.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: Data((line + "\r\n").utf8))
        try file.synchronize()
    }
}
