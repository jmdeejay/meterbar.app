import Foundation

/// `URLProtocol` subclass that intercepts requests on a custom `URLSession`
/// and serves canned `(Data, HTTPURLResponse)` (or `Error`) tuples keyed by
/// matching predicate.
///
/// Usage:
/// ```swift
/// let stub = URLProtocolStub()
/// stub.respond(when: { $0.url?.path == "/some/path" },
///              with: Data(), status: 200, headers: [:])
/// let session = URLProtocolStub.makeURLSession(with: stub)
/// // pass `session` to the service under test
/// ```
///
/// Each `URLSession` built by `makeURLSession(with:)` registers `protocolClasses`
/// at the configuration level, so it intercepts **only** requests made through
/// that session — never `URLSession.shared`.
final class URLProtocolStub: URLProtocol {
    /// One canned response. The first stub whose `match` predicate returns
    /// `true` for the incoming request wins.
    struct Response {
        let match: (URLRequest) -> Bool
        let result: Result<(Data, HTTPURLResponse), Error>
    }

    // Shared queue of canned responses. Static so URLProtocol's class-bound
    // entry points (no instance handed to us) can reach them.
    private static let queueLock = NSLock()
    private static var responses: [Response] = []
    private static var recordedRequests: [URLRequest] = []

    // MARK: - Public stub API (instance forwards to static state)

    /// All requests that reached the stub since the most recent `makeURLSession`.
    /// Useful for asserting headers, bodies, query strings.
    var requests: [URLRequest] {
        URLProtocolStub.queueLock.lock()
        defer { URLProtocolStub.queueLock.unlock() }
        return URLProtocolStub.recordedRequests
    }

    /// Queue a canned response. Stubs are matched in FIFO order; first match wins.
    func respond(
        when match: @escaping (URLRequest) -> Bool,
        with data: Data,
        status: Int,
        headers: [String: String] = [:]
    ) {
        URLProtocolStub.queueLock.lock()
        defer { URLProtocolStub.queueLock.unlock() }
        URLProtocolStub.responses.append(Response(
            match: match,
            result: .success((data, Self.makeResponse(status: status, headers: headers, url: nil)))
        ))
    }

    /// Queue a canned failure. The session client receives the error verbatim.
    func failAll(when match: @escaping (URLRequest) -> Bool, with error: Error) {
        URLProtocolStub.queueLock.lock()
        defer { URLProtocolStub.queueLock.unlock() }
        URLProtocolStub.responses.append(Response(
            match: match,
            result: .failure(error)
        ))
    }

    /// Reset all queued stubs and recorded requests. Called automatically by
    /// `makeURLSession(with:)` so each new session starts clean.
    func reset() {
        URLProtocolStub.queueLock.lock()
        defer { URLProtocolStub.queueLock.unlock() }
        URLProtocolStub.responses.removeAll()
        URLProtocolStub.recordedRequests.removeAll()
    }

    /// Build a `URLSession` that routes every request through `URLProtocolStub`.
    static func makeURLSession(with stub: URLProtocolStub) -> URLSession {
        stub.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: config)
    }

    // MARK: - URLProtocol overrides

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.queueLock.lock()
        Self.recordedRequests.append(request)
        let matched = Self.responses.first { $0.match(request) }
        Self.queueLock.unlock()

        guard let response = matched else {
            client?.urlProtocol(self, didFailWithError: NSError(
                domain: "URLProtocolStub", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No stub matched request: \(request.url?.absoluteString ?? "?")"]
            ))
            return
        }

        switch response.result {
        case .success(let (data, httpResponse)):
            // Re-emit the HTTPURLResponse bound to the incoming URL.
            let bound = Self.makeResponse(
                status: httpResponse.statusCode,
                headers: httpResponse.allHeaderFields as? [String: String] ?? [:],
                url: request.url
            )
            client?.urlProtocol(self, didReceive: bound, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    // MARK: - Helpers

    private static func makeResponse(status: Int, headers: [String: String], url: URL?) -> HTTPURLResponse {
        let resolvedURL = url ?? URL(string: "https://stub.local/")!
        return HTTPURLResponse(
            url: resolvedURL,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }
}
