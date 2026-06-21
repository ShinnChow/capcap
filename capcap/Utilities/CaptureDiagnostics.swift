import Foundation

/// Temporary file-backed diagnostics for capture latency investigations.
/// Kept separate from the crash/error log so repro traces are easy to collect.
enum CaptureDiagnostics {
    private static let lock = NSLock()
    private static let directoryName = "capcap"
    private static let fileName = "window-capture-diagnostics.log"
    private static let maxLogBytes = 4_000_000
    private static let trimToBytes = 2_500_000
    private static var didResetForProcess = false

    private static var isEnabled: Bool {
        _isDebugAssertConfiguration()
            || ProcessInfo.processInfo.environment["CAPCAP_CAPTURE_DIAGNOSTICS"] == "1"
            || UserDefaults.standard.bool(forKey: "captureDiagnosticsEnabled")
    }

    static var logURL: URL? {
        guard let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return nil
        }
        return logs
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    static func resetForProcessIfNeeded() {
        guard isEnabled else { return }

        lock.lock()
        let shouldReset = !didResetForProcess
        if shouldReset {
            didResetForProcess = true
            if let url = logURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
        lock.unlock()

        if shouldReset {
            log("session-start", metadata: [
                "logPath": logURL?.path ?? "nil",
                "system": DiagnosticLog.systemSnapshot(),
            ])
        }
    }

    @discardableResult
    static func measure<T>(
        _ event: String,
        metadata: [String: Any] = [:],
        file: StaticString = #fileID,
        line: UInt = #line,
        _ work: () -> T
    ) -> T {
        guard isEnabled else { return work() }

        log("\(event)-begin", metadata: metadata, file: file, line: line)
        let start = ProcessInfo.processInfo.systemUptime
        let result = work()
        var finishedMetadata = metadata
        finishedMetadata["durationMs"] = elapsedMilliseconds(since: start)
        log("\(event)-end", metadata: finishedMetadata, file: file, line: line)
        return result
    }

    static func log(
        _ event: String,
        metadata: [String: Any] = [:],
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        guard isEnabled else { return }

        guard let data = makeLine(
            event: event,
            metadata: metadata,
            file: String(describing: file),
            line: line
        ).data(using: .utf8) else {
            return
        }

        lock.lock()
        defer { lock.unlock() }
        append(data)
    }

    static func elapsedMilliseconds(since start: TimeInterval) -> String {
        String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - start) * 1000)
    }

    static func rect(_ rect: CGRect) -> String {
        "x=\(number(rect.origin.x)),y=\(number(rect.origin.y)),w=\(number(rect.size.width)),h=\(number(rect.size.height))"
    }

    static func size(_ size: CGSize) -> String {
        "w=\(number(size.width)),h=\(number(size.height))"
    }

    private static func makeLine(
        event: String,
        metadata: [String: Any],
        file: String,
        line: UInt
    ) -> String {
        let timestamp = ISO8601DateFormatter.captureDiagnostic.string(from: Date())
        let thread = Thread.isMainThread ? "main" : "background"
        var parts = [
            "\(timestamp)",
            "pid=\(ProcessInfo.processInfo.processIdentifier)",
            "thread=\(thread)",
            "event=\(sanitize(event))",
        ]
        if !metadata.isEmpty {
            let fields = metadata.keys.sorted().map { key in
                "\(sanitize(key))=\(sanitize(String(describing: metadata[key] ?? "")))"
            }
            parts.append(contentsOf: fields)
        }
        parts.append("source=\(sanitize(file)):\(line)")
        return parts.joined(separator: " ") + "\n"
    }

    private static func append(_ data: Data) {
        guard let url = logURL else { return }
        let directory = url.deletingLastPathComponent()
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) {
                _ = fm.createFile(atPath: url.path, contents: nil)
            }
            trimIfNeeded(at: url)
            let handle = try FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
            handle.write(data)
            handle.synchronizeFile()
            handle.closeFile()
        } catch {
            NSLog("[capcap] CaptureDiagnostics append failed: \(error.localizedDescription)")
        }
    }

    private static func trimIfNeeded(at url: URL) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        guard (values?.fileSize ?? 0) > maxLogBytes,
              let existing = try? Data(contentsOf: url),
              existing.count > trimToBytes else {
            return
        }

        var trimmed = Data()
        if let marker = "\n--- earlier capture diagnostic log lines truncated ---\n".data(using: .utf8) {
            trimmed.append(marker)
        }
        trimmed.append(existing.suffix(trimToBytes))
        try? trimmed.write(to: url, options: .atomic)
    }

    private static func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private static func number(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }
}

private extension ISO8601DateFormatter {
    static var captureDiagnostic: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone.current
        return formatter
    }
}
