import AppKit
import AVFoundation
import ImageIO

struct HistoryImagePreview {
    let cgImage: CGImage?
    let pixelWidth: Int
    let pixelHeight: Int

    static func load(url: URL, pixelSize: Int) -> HistoryImagePreview {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return HistoryImagePreview(cgImage: nil, pixelWidth: 0, pixelHeight: 0)
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixelWidth = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let pixelHeight = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize
        ]
        let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        return HistoryImagePreview(cgImage: cgImage, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    static func loadVideoFrame(url: URL, pixelSize: Int) -> HistoryImagePreview {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: pixelSize, height: pixelSize)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        do {
            let cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
            let size = videoPixelSize(for: asset) ?? CGSize(width: cgImage.width, height: cgImage.height)
            return HistoryImagePreview(
                cgImage: cgImage,
                pixelWidth: Int(round(size.width)),
                pixelHeight: Int(round(size.height))
            )
        } catch {
            return HistoryImagePreview(cgImage: nil, pixelWidth: 0, pixelHeight: 0)
        }
    }

    static func metadata(pixelWidth: Int, pixelHeight: Int, date: Date) -> String {
        let size: String
        if pixelWidth > 0, pixelHeight > 0 {
            size = "\(pixelWidth) x \(pixelHeight)"
        } else {
            size = "Image"
        }
        return "\(size)  ·  \(dateFormatter.string(from: date))"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MdHm")
        return formatter
    }()

    private static func videoPixelSize(for asset: AVAsset) -> CGSize? {
        guard let track = asset.tracks(withMediaType: .video).first else { return nil }
        let transformed = track.naturalSize.applying(track.preferredTransform)
        let size = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        guard size.width > 0, size.height > 0 else { return nil }
        return size
    }
}

final class HistoryImagePreviewRequest {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

final class HistoryImagePreviewLoader {
    static let shared = HistoryImagePreviewLoader()

    private let queue = DispatchQueue(label: "capcap.historyPreviewLoader", qos: .utility)
    private let cache = NSCache<NSString, HistoryImagePreviewCacheValue>()

    private init() {
        cache.countLimit = 180
    }

    @discardableResult
    func load(
        url: URL,
        pixelSize: Int,
        completion: @escaping (HistoryImagePreview) -> Void
    ) -> HistoryImagePreviewRequest {
        load(url: url, pixelSize: pixelSize, cachePrefix: "image", producer: HistoryImagePreview.load, completion: completion)
    }

    @discardableResult
    func loadVideoFrame(
        url: URL,
        pixelSize: Int,
        completion: @escaping (HistoryImagePreview) -> Void
    ) -> HistoryImagePreviewRequest {
        load(
            url: url,
            pixelSize: pixelSize,
            cachePrefix: "video",
            producer: HistoryImagePreview.loadVideoFrame,
            completion: completion
        )
    }

    @discardableResult
    private func load(
        url: URL,
        pixelSize: Int,
        cachePrefix: String,
        producer: @escaping (URL, Int) -> HistoryImagePreview,
        completion: @escaping (HistoryImagePreview) -> Void
    ) -> HistoryImagePreviewRequest {
        let request = HistoryImagePreviewRequest()
        let key = cacheKey(url: url, pixelSize: pixelSize, cachePrefix: cachePrefix)

        if let cached = cache.object(forKey: key) {
            DispatchQueue.main.async { [request] in
                guard !request.isCancelled else { return }
                completion(cached.preview)
            }
            return request
        }

        queue.async { [weak self, request] in
            guard let self, !request.isCancelled else { return }
            if let cached = self.cache.object(forKey: key) {
                DispatchQueue.main.async { [request] in
                    guard !request.isCancelled else { return }
                    completion(cached.preview)
                }
                return
            }

            let preview = producer(url, pixelSize)
            guard !request.isCancelled else { return }
            self.cache.setObject(HistoryImagePreviewCacheValue(preview: preview), forKey: key)
            DispatchQueue.main.async { [request] in
                guard !request.isCancelled else { return }
                completion(preview)
            }
        }

        return request
    }

    private func cacheKey(url: URL, pixelSize: Int, cachePrefix: String) -> NSString {
        "\(cachePrefix)#\(url.path)#\(pixelSize)" as NSString
    }
}

private final class HistoryImagePreviewCacheValue: NSObject {
    let preview: HistoryImagePreview

    init(preview: HistoryImagePreview) {
        self.preview = preview
    }
}
