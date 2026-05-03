import AppKit
import UniformTypeIdentifiers

enum FinderSelection {
    /// Returns the URL when Finder has exactly one image file selected,
    /// otherwise nil. Triggers the Apple Events permission prompt on first
    /// use; on permission denial or any failure, returns nil so the caller
    /// can fall back to normal screenshot flow.
    static func currentImageFileURL() -> URL? {
        let urls = currentSelectionURLs()
        guard urls.count == 1, let url = urls.first else { return nil }
        guard isImage(url) else { return nil }
        return url
    }

    private static func currentSelectionURLs() -> [URL] {
        let source = """
        tell application "Finder"
            set sel to selection
            set out to {}
            repeat with f in sel
                try
                    set end of out to POSIX path of (f as alias)
                end try
            end repeat
            return out
        end tell
        """

        guard let script = NSAppleScript(source: source) else { return [] }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if error != nil { return [] }

        var urls: [URL] = []
        // AppleScript returns a list descriptor; items are 1-indexed.
        let count = result.numberOfItems
        if count == 0 { return [] }
        for i in 1...count {
            if let path = result.atIndex(i)?.stringValue {
                urls.append(URL(fileURLWithPath: path))
            }
        }
        return urls
    }

    private static func isImage(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey])
        guard let type = values?.contentType else { return false }
        return type.conforms(to: .image)
    }
}
