import Foundation

/// Streams a large file to disk, resuming from whatever a previous attempt left in the `.part` file.
/// One URLSession, delegate callbacks on a serial queue, so per-transfer state needs no extra locking
/// beyond the dictionary that maps tasks to transfers.
public final class FileDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public typealias Progress = @Sendable (_ received: Int64, _ total: Int64) -> Void

    private final class Transfer {
        let handle: FileHandle
        let resumedFrom: Int64
        var received: Int64
        let total: Int64
        let progress: Progress?
        let digest: Checksum.Digest?
        let continuation: CheckedContinuation<Void, Error>
        var lastReport = Date.distantPast

        init(handle: FileHandle, resumedFrom: Int64, total: Int64, progress: Progress?,
             digest: Checksum.Digest?, continuation: CheckedContinuation<Void, Error>) {
            self.handle = handle
            self.resumedFrom = resumedFrom
            self.received = resumedFrom
            self.total = total
            self.progress = progress
            self.digest = digest
            self.continuation = continuation
        }
    }

    private var session: URLSession!
    private var transfers: [Int: Transfer] = [:]
    private let lock = NSLock()

    public convenience override init() {
        self.init(configuration: .default)
    }

    /// `configuration` is for tests (a mock URLProtocol); the app uses the default.
    init(configuration config: URLSessionConfiguration) {
        super.init()
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 12 * 60 * 60
        config.httpAdditionalHeaders = ["User-Agent": AppInfo.userAgent]
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    /// Downloads `url` into `partURL`. Returns when the transfer ends; the caller checks size and checksum.
    /// With a `digest`, every byte of the file is hashed as it's written (including what a previous attempt
    /// left behind), so verifying doesn't mean reading the whole file back from disk.
    public func download(_ url: URL, to partURL: URL, expectedSize: Int64,
                         digest: Checksum.Digest? = nil, progress: Progress? = nil) async throws {
        let fm = FileManager.default
        var existing = Self.size(of: partURL)
        if existing > expectedSize {
            try fm.removeItem(at: partURL)
            existing = 0
        }
        if existing > 0 { try digest?.update(contentsOf: partURL) }
        if existing == expectedSize, existing > 0 { return }
        if !fm.fileExists(atPath: partURL.path) {
            fm.createFile(atPath: partURL.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: partURL)
        try handle.seekToEnd()

        var request = URLRequest(url: url)
        if existing > 0 {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
        }
        let task = session.dataTask(with: request)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    transfers[task.taskIdentifier] = Transfer(handle: handle, resumedFrom: existing,
                                                              total: expectedSize, progress: progress,
                                                              digest: digest, continuation: continuation)
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    static func size(of url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: URLSessionDataDelegate

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                           didReceive response: URLResponse,
                           completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let transfer = lock.withLock({ transfers[dataTask.taskIdentifier] }) else {
            completionHandler(.cancel)
            return
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        switch status {
        case 206:
            completionHandler(.allow)
        case 200:
            // Server ignored the Range header: start over.
            if transfer.resumedFrom > 0 {
                try? transfer.handle.truncate(atOffset: 0)
                transfer.received = 0
                transfer.digest?.reset()
            }
            completionHandler(.allow)
        default:
            completionHandler(.cancel)
            finish(dataTask.taskIdentifier, error: MirrorError.http(response.url ?? URL(fileURLWithPath: "/"), status))
        }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let transfer = lock.withLock({ transfers[dataTask.taskIdentifier] }) else { return }
        do {
            try transfer.handle.write(contentsOf: data)
        } catch {
            dataTask.cancel()
            finish(dataTask.taskIdentifier, error: error)
            return
        }
        transfer.digest?.update(data)
        transfer.received += Int64(data.count)
        let now = Date()
        if now.timeIntervalSince(transfer.lastReport) >= 0.5 {
            transfer.lastReport = now
            transfer.progress?(transfer.received, transfer.total)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        var error = error
        if error == nil, let status = (task.response as? HTTPURLResponse)?.statusCode, status != 200, status != 206 {
            error = MirrorError.http(task.originalRequest?.url ?? URL(fileURLWithPath: "/"), status)
        }
        if let transfer = lock.withLock({ transfers[task.taskIdentifier] }), error == nil {
            transfer.progress?(transfer.received, transfer.total)
        }
        finish(task.taskIdentifier, error: error)
    }

    private func finish(_ id: Int, error: Error?) {
        guard let transfer = lock.withLock({ transfers.removeValue(forKey: id) }) else { return }
        try? transfer.handle.close()
        if let error {
            transfer.continuation.resume(throwing: error)
        } else {
            transfer.continuation.resume()
        }
    }
}
