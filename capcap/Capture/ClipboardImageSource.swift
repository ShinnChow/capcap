import AppKit
import UniformTypeIdentifiers

/// Pulls an editable image out of the system clipboard for explicit edit and
/// pin shortcuts.
enum ClipboardImageSource {
    /// Returns an image when the clipboard holds one — either raw bitmap data
    /// (a copied screenshot, an image dragged from a browser, etc.) or a
    /// single copied image file. Returns nil when the clipboard has no image.
    static func currentImage() -> NSImage? {
        let pasteboard = NSPasteboard.general

        // A copied image file (e.g. ⌘C on a file in Finder) takes priority.
        // Finder puts the file's *icon* on the clipboard as TIFF data too, so
        // the raw-bitmap path below would decode that generic document icon
        // instead of the real image. Load from the file URL first.
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL],
           urls.count == 1,
           isImage(urls[0]),
           let data = try? Data(contentsOf: urls[0]),
           let rep = NSBitmapImageRep(data: data) {
            return image(from: rep)
        }

        // Otherwise fall back to raw bitmap data: a copied screenshot or web
        // image. Decode through NSBitmapImageRep so the editor canvas works at
        // the image's true pixel resolution rather than DPI-scaled points.
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type),
               let rep = NSBitmapImageRep(data: data) {
                return image(from: rep)
            }
        }

        return nil
    }

    /// Empties the clipboard. Used by pin mode so the same source is not
    /// re-pinned.
    static func clear() {
        NSPasteboard.general.clearContents()
    }

    /// Wraps a decoded bitmap in an NSImage sized to its pixel dimensions, so
    /// the editor canvas bounds match the image's full resolution.
    private static func image(from rep: NSBitmapImageRep) -> NSImage? {
        let pixelSize = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        rep.size = pixelSize
        let image = NSImage(size: pixelSize)
        image.addRepresentation(rep)
        return image
    }

    private static func isImage(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey])
        guard let type = values?.contentType else { return false }
        return type.conforms(to: .image)
    }
}
