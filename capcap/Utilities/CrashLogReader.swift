import Foundation

/// Locates and reads the most recent macOS crash report for capcap so the
/// user can copy it into a bug report.
enum CrashLogReader {
    /// A crash report file on disk — its URL plus when it was written.
    struct Entry {
        let url: URL
        let date: Date
    }

    /// macOS names crash reports "<process>-<timestamp>.<ext>"; the process
    /// name matches capcap's CFBundleExecutable.
    private static let processName = "capcap"

    /// Scans the standard DiagnosticReports directories and returns the newest
    /// crash report belonging to capcap, or nil if the app has never crashed.
    /// This only stats the directory — it does not read any file contents.
    static func latestCrashFile() -> Entry? {
        let fm = FileManager.default
        guard let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dirs = [
            library.appendingPathComponent("Logs/DiagnosticReports", isDirectory: true),
            library.appendingPathComponent("Logs/DiagnosticReports/Retired", isDirectory: true),
        ]

        var newest: Entry?
        for dir in dirs {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in entries {
                let ext = url.pathExtension.lowercased()
                guard ext == "ips" || ext == "crash" else { continue }
                guard url.lastPathComponent.hasPrefix(processName + "-") else { continue }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if newest == nil || date > newest!.date {
                    newest = Entry(url: url, date: date)
                }
            }
        }
        return newest
    }

    /// Reads a crash report and returns a human-readable rendering. Modern
    /// `.ips` reports are a one-line JSON header followed by a JSON body; both
    /// are pretty-printed when possible, falling back to the raw text.
    static func readableText(at url: URL) -> String {
        let raw: String
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            raw = utf8
        } else if let data = try? Data(contentsOf: url) {
            raw = String(decoding: data, as: UTF8.self)
        } else {
            return ""
        }

        guard url.pathExtension.lowercased() == "ips",
              let newline = raw.firstIndex(of: "\n") else {
            return raw
        }
        let header = String(raw[..<newline])
        let body = String(raw[raw.index(after: newline)...])
        guard let prettyHeader = prettyJSON(header),
              let prettyBody = prettyJSON(body) else {
            return raw
        }
        return prettyHeader + "\n\n" + prettyBody
    }

    private static func prettyJSON(_ string: String) -> String? {
        guard let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ) else {
            return nil
        }
        return String(decoding: pretty, as: UTF8.self)
    }
}
