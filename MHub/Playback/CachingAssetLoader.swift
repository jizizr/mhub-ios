import AVFoundation
import Foundation
import MHubKit
import UniformTypeIdentifiers

/// Streams one song to AVPlayer while writing the same bytes to disk, so the
/// network is used once for both playback and the offline cache.
///
/// The file is downloaded sequentially into a partial file; AVPlayer's
/// byte-range requests are answered from that file as it grows. When the
/// download finishes the file moves into `AudioCache`. All state is confined to
/// `queue`, which is also the resource-loader and URLSession delegate queue.
final class CachingAssetLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate, @unchecked Sendable {
    let asset: AVURLAsset
    let key: String

    private let remote: URL
    private let track: Track
    private let quality: Quality
    private let cache: AudioCache
    private let onCached: @Sendable () -> Void
    private let queue = DispatchQueue(label: "mhub.asset-loader")
    private let partial: URL
    private var session: URLSession?
    private var writer: FileHandle?
    private var reader: FileHandle?
    private var pending: [AVAssetResourceLoadingRequest] = []
    private var contentLength: Int64?
    private var contentType = "public.audio"
    private var fileExtension = "audio"
    private var downloaded: Int64 = 0
    private var finished = false
    private var failure: Error?
    private var cancelled = false

    private static let scheme = "mhub-stream"

    init(remote: URL, key: String, track: Track, quality: Quality, cache: AudioCache,
         onCached: @escaping @Sendable () -> Void) {
        self.remote = remote
        self.key = key
        self.track = track
        self.quality = quality
        self.cache = cache
        self.onCached = onCached
        partial = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".part")
        var components = URLComponents(url: remote, resolvingAgainstBaseURL: false)
        components?.scheme = Self.scheme
        asset = AVURLAsset(url: components?.url ?? remote)
        super.init()
        asset.resourceLoader.setDelegate(self, queue: queue)
        queue.async { self.start() }
    }

    /// Stops downloading and deletes the partial file unless it completed.
    func cancel() {
        queue.async {
            guard !self.cancelled else { return }
            self.cancelled = true
            self.session?.invalidateAndCancel()
            self.session = nil
            try? self.writer?.close()
            try? self.reader?.close()
            try? FileManager.default.removeItem(at: self.partial)
            for request in self.pending { request.finishLoading(with: CancellationError()) }
            self.pending.removeAll()
        }
    }

    private func start() {
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        writer = try? FileHandle(forWritingTo: partial)
        reader = try? FileHandle(forReadingFrom: partial)
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = queue
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        self.session = session
        session.dataTask(with: URLRequest(url: remote)).resume()
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            failure = APIError.http(status: status, detail: "")
            completionHandler(.cancel)
            serve()
            return
        }
        if response.expectedContentLength > 0 { contentLength = response.expectedContentLength }
        let mime = response.mimeType ?? "audio/mp4"
        let type = UTType(mimeType: mime == "audio/m4a" ? "audio/mp4" : mime)
        contentType = type?.identifier ?? "public.audio"
        fileExtension = type?.preferredFilenameExtension ?? (mime.contains("flac") ? "flac" : "m4a")
        completionHandler(.allow)
        serve()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !cancelled else { return }
        try? writer?.write(contentsOf: data)
        downloaded += Int64(data.count)
        serve()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !cancelled else { return }
        try? writer?.close()
        writer = nil
        if let error {
            failure = error
        } else {
            finished = true
            if contentLength == nil { contentLength = downloaded }
            commit()
        }
        serve()
        session.finishTasksAndInvalidate()
    }

    private func commit() {
        // Copy, because AVPlayer may still read the partial file.
        let copy = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard (try? FileManager.default.copyItem(at: partial, to: copy)) != nil else { return }
        let key = key, ext = fileExtension, track = track, quality = quality, cache = cache, onCached = onCached
        Task {
            await cache.commit(copy, key: key, fileExtension: ext, track: track, quality: quality)
            onCached()
        }
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard !cancelled else { return false }
        pending.append(loadingRequest)
        serve()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        pending.removeAll { $0 === loadingRequest }
    }

    /// Answers every pending request as far as the downloaded bytes allow.
    private func serve() {
        pending.removeAll { request in
            if request.isCancelled { return true }
            if let failure, !finished {
                request.finishLoading(with: failure)
                return true
            }
            guard let length = contentLength else { return false }
            if let info = request.contentInformationRequest {
                info.contentType = contentType
                info.contentLength = length
                info.isByteRangeAccessSupported = true
            }
            guard let dataRequest = request.dataRequest else {
                request.finishLoading()
                return true
            }
            let end = dataRequest.requestsAllDataToEndOfResource
                ? length : min(length, dataRequest.requestedOffset + Int64(dataRequest.requestedLength))
            while dataRequest.currentOffset < end && dataRequest.currentOffset < downloaded {
                let count = min(end, downloaded) - dataRequest.currentOffset
                let chunk = Int(min(count, 512 << 10))
                guard let reader, (try? reader.seek(toOffset: UInt64(dataRequest.currentOffset))) != nil,
                      let data = try? reader.read(upToCount: chunk), !data.isEmpty else { break }
                dataRequest.respond(with: data)
            }
            if dataRequest.currentOffset >= end {
                request.finishLoading()
                return true
            }
            if finished {
                // The server sent less than it declared.
                request.finishLoading(with: URLError(.networkConnectionLost))
                return true
            }
            return false
        }
    }
}
