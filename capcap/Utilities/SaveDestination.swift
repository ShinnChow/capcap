import Foundation

enum SaveDestination {
    static func displayPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL.path
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    static func uniqueFile(in directory: URL, fileName: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let original = directory.appendingPathComponent(fileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: original.path) else {
            return original
        }

        let nsName = fileName as NSString
        let rawBase = nsName.deletingPathExtension
        let fileExtension = nsName.pathExtension
        let base = rawBase.isEmpty ? "capcap" : rawBase

        for index in 2...999 {
            let candidateName: String
            if fileExtension.isEmpty {
                candidateName = "\(base) \(index)"
            } else {
                candidateName = "\(base) \(index).\(fileExtension)"
            }

            let candidate = directory.appendingPathComponent(candidateName, isDirectory: false)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        let token = UUID().uuidString.prefix(8).lowercased()
        let fallbackName: String
        if fileExtension.isEmpty {
            fallbackName = "\(base)-\(token)"
        } else {
            fallbackName = "\(base)-\(token).\(fileExtension)"
        }
        return directory.appendingPathComponent(fallbackName, isDirectory: false)
    }
}
