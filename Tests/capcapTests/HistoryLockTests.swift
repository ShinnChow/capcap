import Foundation
import XCTest
@testable import capcap

/// Frozen oracle for the per-item history lock (spec examples E1–E5).
/// Expected values are stated from the spec, independent of the implementation.
final class HistoryLockTests: XCTestCase {
    private var directoryURL: URL!

    override func setUpWithError() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directoryURL {
            try? FileManager.default.removeItem(at: directoryURL)
        }
    }

    // E1 — locking a writable file persists to disk and is readable back.
    func testSetLockedLocksAndPersists() throws {
        let f = try makeFile(name: "image.png", contents: Data([0x01]))

        XCTAssertTrue(HistoryManager.setLocked(true, on: f))
        XCTAssertTrue(HistoryManager.isLocked(url: f))

        // A freshly constructed URL over the same path must also observe the attribute.
        let freshURL = URL(fileURLWithPath: f.path)
        XCTAssertTrue(HistoryManager.isLocked(url: freshURL))

        // Shell cross-check: the OS `xattr` tool reads the same attribute over a
        // different code path than capcap's getxattr, and must print "1".
        XCTAssertEqual(try shellLockedXattrValue(of: f), "1")
    }

    // E2 — a write to a path that cannot exist reports failure, never success.
    func testSetLockedFailsForUnwritablePath() throws {
        let missing = URL(fileURLWithPath: "/nonexistent-capcap-dir-4f2a/x.png")

        XCTAssertFalse(HistoryManager.setLocked(true, on: missing))
        XCTAssertFalse(HistoryManager.isLocked(url: missing))
    }

    // E3 — unlocking a file that was never locked is already the requested
    // state, so it counts as success (ENOATTR is not a failure here).
    func testSetLockedUnlockAlreadyUnlockedIsSuccess() throws {
        let f = try makeFile(name: "plain.png", contents: Data([0x02]))

        XCTAssertTrue(HistoryManager.setLocked(false, on: f))
        XCTAssertFalse(HistoryManager.isLocked(url: f))
    }

    // R6 — lock/unlock round trip on one file. Exercises the removexattr-success
    // path (unlocking a file that IS locked), which the ENOATTR edge in E3 does
    // not, and proves the attribute round-trips rather than sticking.
    func testSetLockedRoundTripOnSameFile() throws {
        let f = try makeFile(name: "round-trip.png", contents: Data([0x01]))

        XCTAssertTrue(HistoryManager.setLocked(true, on: f))
        XCTAssertTrue(HistoryManager.isLocked(url: f))

        XCTAssertTrue(HistoryManager.setLocked(false, on: f))
        XCTAssertFalse(HistoryManager.isLocked(url: f))

        // Re-locking proves the state is not sticky and the attribute round-trips.
        XCTAssertTrue(HistoryManager.setLocked(true, on: f))
        XCTAssertTrue(HistoryManager.isLocked(url: f))
    }

    // E4 — "delete all history" keeps locked entries and reports how many it kept.
    func testClearAllKeepsLockedEntries() throws {
        let locked = try makeFile(name: "locked.png", contents: Data([0x01]))
        let plain = try makeFile(name: "plain.png", contents: Data([0x02]))
        XCTAssertTrue(HistoryManager.setLocked(true, on: locked))

        let candidates = [locked, plain]
        let decision = HistoryManager.partitionEntriesForRemoval(candidates)

        XCTAssertEqual(decision.kept, [locked])
        XCTAssertEqual(decision.remove, [plain])

        // Performing the removal the way production does leaves the locked file on disk.
        for url in decision.remove {
            try? FileManager.default.removeItem(at: url)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: plain.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: locked.path))
    }

    @discardableResult
    private func makeFile(name: String, contents: Data) throws -> URL {
        let url = directoryURL.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    /// Runs `/usr/bin/xattr -p com.capcap.locked <path>` and returns its stdout,
    /// reading the attribute through the OS tool rather than capcap's getxattr.
    private func shellLockedXattrValue(of url: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-p", "com.capcap.locked", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
}
