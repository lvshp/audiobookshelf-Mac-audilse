import Foundation
import Darwin

struct ShareHTTPResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let data: Data
    let actualRange: Range<Int64>?
    let totalLength: Int64?
    func header(_ name: String) -> String? { headers[name.lowercased()] }
}
enum ShareResponsePolicy: Sendable {
    case bounded(Int)
    case range(offset: Int64, length: Int)
    case export(URL)
}

/// One isolated, cancellable transfer. Data is rejected at response headers or
/// before appending a chunk beyond the cap; Range 200 bodies are never collected.
final class ShareHTTPTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ShareHTTPResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var cancelled = false
    private var failure: PublicShareError?
    private var response: HTTPURLResponse?
    private var headers: [String: String] = [:]
    private var data = Data()
    private var range: Range<Int64>?
    private var total: Int64?
    private var maximum = 0
    private var file: FileHandle?
    private let policy: ShareResponsePolicy
    init(policy: ShareResponsePolicy) { self.policy = policy }

    func perform(_ input: URLRequest) async throws -> ShareHTTPResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let config = URLSessionConfiguration.ephemeral
                config.httpShouldSetCookies = false; config.httpCookieStorage = nil
                config.urlCredentialStorage = nil; config.urlCache = nil
                config.requestCachePolicy = .reloadIgnoringLocalCacheData
                config.timeoutIntervalForRequest = 15
                if case .export = policy { config.timeoutIntervalForResource = 24 * 3600 }
                else { config.timeoutIntervalForResource = 60 }
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
                var request = input; request.httpShouldHandleCookies = false
                let task = session.dataTask(with: request)
                let start = lock.withLock {
                    guard !cancelled else { return false }
                    self.continuation = continuation; self.session = session; self.task = task
                    return true
                }
                if start { task.resume() }
                else { session.invalidateAndCancel(); continuation.resume(throwing: PublicShareError.transport(NSURLErrorCancelled)) }
            }
        } onCancel: { self.cancel() }
    }
    func cancel() {
        let task = lock.withLock { cancelled = true; return self.task }
        task?.cancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Normal TLS validation remains enabled; never consult stored HTTP credentials.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust { completionHandler(.performDefaultHandling, nil) }
        else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let allowed = lock.withLock { () -> Bool in
            guard let response = response as? HTTPURLResponse else { failure = .invalidResponse; return false }
            self.response = response
            headers = response.allHeaderFields.reduce(into: [:]) { result, field in
                result[String(describing: field.key).lowercased()] = String(describing: field.value)
            }
            switch policy {
            case .bounded(let limit): maximum = limit
            case .range(let offset, let length):
                if response.statusCode == 200 { failure = .rangeIgnored; return false }
                if response.statusCode == 416 {
                    let value = headers["content-range"]?.split(separator: "/").last.flatMap { Int64($0) }
                    failure = .rangeNotSatisfiable(totalLength: value); return false
                }
                guard response.statusCode == 206 else { maximum = 4096; break }
                guard headers["content-encoding"].map({ $0.lowercased() == "identity" }) ?? true,
                      let raw = headers["content-range"], let parsed = Self.parseRange(raw),
                      parsed.0.lowerBound == offset, parsed.0.count <= length,
                      parsed.0.upperBound - parsed.0.lowerBound <= Int64(length) else { failure = .invalidRange; return false }
                range = parsed.0; total = parsed.1; maximum = Int(parsed.0.upperBound - parsed.0.lowerBound)
                if response.expectedContentLength >= 0, response.expectedContentLength != Int64(maximum) { failure = .invalidRange; return false }
            case .export(let destination):
                guard response.statusCode == 200 else { maximum = 4096; break }
                let fd = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { failure = .transport(NSURLErrorCannotCreateFile); return false }
                file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                maximum = 0
            }
            if file == nil, response.expectedContentLength > Int64(maximum) { failure = .responseTooLarge; return false }
            return true
        }
        completionHandler(allowed ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        let cancel = lock.withLock { () -> Bool in
            guard failure == nil else { return true }
            if let file {
                do { try file.write(contentsOf: chunk); return false }
                catch { failure = .transport(NSURLErrorCannotWriteToFile); return true }
            }
            guard chunk.count <= maximum - data.count else { failure = .responseTooLarge; return true }
            data.append(chunk); return false
        }
        if cancel { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let completion = lock.withLock { () -> (CheckedContinuation<ShareHTTPResponse, Error>?, Result<ShareHTTPResponse, Error>) in
            defer { continuation = nil; self.task = nil; self.session = nil }
            if let file {
                do { try file.synchronize(); try file.close() }
                catch { failure = failure ?? .transport(NSURLErrorCannotWriteToFile) }
                self.file = nil
            }
            if let failure { return (continuation, .failure(failure)) }
            if cancelled { return (continuation, .failure(PublicShareError.transport(NSURLErrorCancelled))) }
            if let error { return (continuation, .failure(PublicShareError.transport((error as NSError).code))) }
            guard let response else { return (continuation, .failure(PublicShareError.invalidResponse)) }
            if let range, data.count != range.count { return (continuation, .failure(PublicShareError.invalidResponse)) }
            return (continuation, .success(.init(status: response.statusCode, headers: headers, data: data, actualRange: range, totalLength: total)))
        }
        session.finishTasksAndInvalidate()
        completion.0?.resume(with: completion.1)
    }
    private static func parseRange(_ value: String) -> (Range<Int64>, Int64)? {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        let sizes = parts[1].split(separator: "/", omittingEmptySubsequences: false)
        guard sizes.count == 2, let total = Int64(sizes[1]), total > 0 else { return nil }
        let bounds = sizes[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]), start >= 0, end >= start, end < total else { return nil }
        return (start..<(end + 1), total)
    }
}
