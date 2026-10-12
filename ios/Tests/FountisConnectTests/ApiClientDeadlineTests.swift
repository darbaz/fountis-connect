import XCTest
@testable import FountisConnect

/// The API client against servers that misbehave: one that answers and then sends a byte at a time forever, one that
/// never answers, one that is just slow. The deadline is a fraction of a second here; production uses 15 s.
///
/// Two kinds of server: a URLProtocol stub (exact and fast) and a real loopback TCP server (so the real URLSession
/// path, sockets included, is what gets bounded).
final class ApiClientDeadlineTests: XCTestCase {
    private let deadline: TimeInterval = 0.6

    override func setUp() {
        super.setUp()
        StubNetwork.reset()
    }

    /// The stub picks its behaviour from the first path component of the base URL.
    private func stubbed(_ behaviour: String) -> ApiClient {
        ApiClient(base: URL(string: "https://connect.test/\(behaviour)")!, key: "pk_test_x", deadline: deadline, protocolClasses: [StubNetwork.self])
    }

    private func assertTimedOut(_ error: Error?, file: StaticString = #filePath, line: UInt = #line) {
        guard let e = error as? URLError else {
            return XCTFail("expected URLError.timedOut, got \(String(describing: error))", file: file, line: line)
        }
        XCTAssertEqual(e.code, .timedOut, file: file, line: line)
    }

    private func capture<T>(_ work: () async throws -> T) async -> Error? {
        do { _ = try await work(); return nil } catch { return error }
    }

    // MARK: URLProtocol stub

    /// The case URLSession's idle timeout cannot catch: a 200 whose body never ends, a byte every 50 ms.
    func testABodyThatTricklesForeverEndsAsATimeoutAtTheDeadline() async {
        let client = stubbed("trickle")
        let started = Date()
        let error = await capture { try await client.surveys(lang: "en") }
        let took = Date().timeIntervalSince(started)
        assertTimedOut(error)
        XCTAssertGreaterThanOrEqual(took, deadline - 0.1, "must not give up early")
        XCTAssertLessThan(took, deadline + 2.5, "a trickling body must not hold the request open")
        XCTAssertTrue(StubNetwork.wasStopped(within: 2), "the connection is cancelled once the request gives up")
    }

    func testAServerThatNeverAnswersEndsAsATimeoutAtTheDeadline() async {
        let client = stubbed("silent")
        let started = Date()
        let error = await capture { try await client.createAttempt(offerId: "o", token: "t", lang: "en") }
        assertTimedOut(error)
        XCTAssertLessThan(Date().timeIntervalSince(started), deadline + 2.5)
    }

    func testEveryCallEndsTheSameWay() async {
        let client = stubbed("trickle")
        assertTimedOut(await capture { try await client.createAttempt(offerId: "o", token: "t", lang: "en") })
        assertTimedOut(await capture { try await client.guestSession(installId: "i") })
        assertTimedOut(await capture { try await client.createGuestAttempt(offerId: "o", guestSession: "g", lang: "en") })
        assertTimedOut(await capture { try await client.putAnswer(code: "q1", value: 1, attemptToken: "a") })
        assertTimedOut(await capture { try await client.consent(attemptToken: "a") })
        assertTimedOut(await capture { try await client.complete(attemptToken: "a") })
    }

    /// `event()` is fire and forget: past the deadline it returns, it neither throws nor hangs.
    func testAnEventPastTheDeadlineIsSwallowed() async {
        let client = stubbed("trickle")
        let started = Date()
        await client.event(offerId: "o", type: "shown")
        XCTAssertLessThan(Date().timeIntervalSince(started), deadline + 2.5)
    }

    func testABodyThatIsSlowButFinishesInTimeStillSucceeds() async throws {
        let client = ApiClient(base: URL(string: "https://connect.test/slow")!, key: "pk_test_x", deadline: 3, protocolClasses: [StubNetwork.self])
        let started = Date()
        let attempt = try await client.createAttempt(offerId: "o", token: "t", lang: "en")
        XCTAssertEqual(attempt["attempt_token"] as? String, "abc")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.25, "sanity: the stub really was slow")
    }

    func testAnOrdinaryReplyIsUnchanged() async throws {
        let attempt = try await stubbed("ok").createAttempt(offerId: "o", token: "t", lang: "en")
        XCTAssertEqual(attempt["attempt_token"] as? String, "abc")
    }

    func testAnApiErrorIsStillAnApiErrorAndNotATimeout() async {
        let error = await capture { try await stubbed("taken").createAttempt(offerId: "o", token: "t", lang: "en") }
        guard let e = error as? APIError else { return XCTFail("expected APIError, got \(String(describing: error))") }
        XCTAssertEqual(e.status, 409)
        XCTAssertEqual(e.code, "already_taken")
    }

    func testTheNextRequestWorksAfterOneTimedOut() async throws {
        let client = ApiClient(base: URL(string: "https://connect.test/flaky")!, key: "pk_test_x", deadline: deadline, protocolClasses: [StubNetwork.self])
        assertTimedOut(await capture { try await client.consent(attemptToken: "a") }) // 1st request: never answers
        let attempt = try await client.createAttempt(offerId: "o", token: "t", lang: "en") // 2nd: answers at once
        XCTAssertEqual(attempt["attempt_token"] as? String, "abc")
    }

    // MARK: real sockets

    /// The real thing: a TCP server on loopback that sends the headers of a 200 and then one byte every 100 ms for
    /// ever. Nothing here is stubbed, so this is URLSession, its sockets and the deadline together.
    func testARealServerThatTricklesTheBodyForeverIsCutOffAtTheDeadline() async throws {
        let closedByClient = expectation(description: "the server saw the client hang up")
        let server = TrickleServer(byteInterval: 0.1, onClientClosed: { closedByClient.fulfill() })
        let port = try server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!

        // The first real request in a test process also pays for the networking stack starting up, which on a busy CI
        // runner can take most of a second. That is not what is timed here, so make one throwaway request first.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (_, reply) = try await session.data(from: base.appendingPathComponent("warmup"))
        XCTAssertEqual((reply as? HTTPURLResponse)?.statusCode, 200, "the loopback server should answer a plain request (\(server.summary))")

        let client = ApiClient(base: base.appendingPathComponent("v1"), key: "pk_test_x", deadline: 2)
        let started = Date()
        let error = await capture { try await client.surveys(lang: "en") }
        let took = Date().timeIntervalSince(started)

        assertTimedOut(error)
        XCTAssertGreaterThanOrEqual(took, 1.9, "must not give up early")
        XCTAssertLessThan(took, 5, "the body kept arriving, so only a total deadline can end this request")
        XCTAssertGreaterThanOrEqual(server.bytesSent, 3, "sanity: the server really was trickling, so this was not an idle timeout (\(server.summary))")
        await fulfillment(of: [closedByClient], timeout: 5)
    }
}

// MARK: - URLProtocol stub

/// A fake network. The behaviour comes from the first path component of the URL:
/// `trickle` 200 + a byte every 50 ms for ever, `silent` no response at all, `slow` a small JSON body in three pieces
/// over about 0.4 s, `ok` an immediate JSON body, `taken` an immediate 409 error body, `flaky` silent for the first
/// request and `ok` after that.
final class StubNetwork: URLProtocol {
    private static let lock = NSLock()
    private static var stopped = 0
    private static var requests = 0

    static func reset() {
        lock.lock()
        stopped = 0
        requests = 0
        lock.unlock()
    }

    /// Whether `stopLoading` was called (the session cancelled the request), waiting a little for it.
    static func wasStopped(within seconds: TimeInterval) -> Bool {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            lock.lock()
            let n = stopped
            lock.unlock()
            if n > 0 { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    private static func nextRequestNumber() -> Int {
        lock.lock()
        defer { lock.unlock() }
        requests += 1
        return requests
    }

    private let flag = NSLock()
    private var cancelled = false
    private var isCancelled: Bool {
        flag.lock()
        defer { flag.unlock() }
        return cancelled
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        var behaviour = url.pathComponents.dropFirst().first ?? "ok"
        if behaviour == "flaky" { behaviour = StubNetwork.nextRequestNumber() == 1 ? "silent" : "ok" }
        let queue = DispatchQueue.global()
        switch behaviour {
        case "silent":
            break
        case "trickle":
            respond(status: 200, headers: ["Content-Type": "application/json", "Content-Length": "1000000"])
            queue.async { [self] in
                while !isCancelled {
                    client?.urlProtocol(self, didLoad: Data("x".utf8))
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
        case "slow":
            let pieces = ["{\"attempt_", "token\":", "\"abc\"}"]
            respond(status: 200, headers: ["Content-Type": "application/json", "Content-Length": "\(pieces.joined().utf8.count)"])
            queue.async { [self] in
                for piece in pieces {
                    Thread.sleep(forTimeInterval: 0.15)
                    if isCancelled { return }
                    client?.urlProtocol(self, didLoad: Data(piece.utf8))
                }
                client?.urlProtocolDidFinishLoading(self)
            }
        case "taken":
            let body = Data("{\"error\":\"already_taken\",\"message\":\"taken\"}".utf8)
            respond(status: 409, headers: ["Content-Type": "application/json"])
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        default:
            let body = Data("{\"attempt_token\":\"abc\"}".utf8)
            respond(status: 200, headers: ["Content-Type": "application/json"])
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        flag.lock()
        cancelled = true
        flag.unlock()
        StubNetwork.lock.lock()
        StubNetwork.stopped += 1
        StubNetwork.lock.unlock()
    }

    private func respond(status: Int, headers: [String: String]) {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }
}

// MARK: - Loopback server

/// A TCP server on 127.0.0.1 for one test, on plain BSD sockets, so nothing but the kernel sits between the test and
/// the SDK. A request for `/warmup` gets an empty 200 and the connection is closed. Any other request gets the headers
/// of a 200 that promises a huge body, then one byte every `byteInterval` seconds until the client hangs up
/// (`onClientClosed`, once) or the test stops the server.
private final class TrickleServer: @unchecked Sendable {
    private let byteInterval: TimeInterval
    private let onClientClosed: @Sendable () -> Void
    private let lock = NSLock()
    private var stopping = false
    private var accepted = 0
    private var requests = 0
    private var sent = 0
    private var reportedClose = false

    init(byteInterval: TimeInterval, onClientClosed: @escaping @Sendable () -> Void) {
        self.byteInterval = byteInterval
        self.onClientClosed = onClientClosed
    }

    private func locked<R>(_ body: () -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var bytesSent: Int { locked { sent } }

    /// What the server saw, for failure messages: it tells a client that never connected from one that never got an answer.
    var summary: String { locked { "server saw \(accepted) connection(s), \(requests) request(s), \(sent) trickled byte(s)" } }

    private var isStopping: Bool { locked { stopping } }

    /// Binds a free port on 127.0.0.1 and starts accepting. Returns the port.
    func start() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) } }
        var port: UInt16 = 0
        if bound == 0, listen(fd, 16) == 0 {
            var name = sockaddr_in()
            var length = size
            let named = withUnsafeMutablePointer(to: &name) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
            if named == 0 { port = UInt16(bigEndian: name.sin_port) }
        }
        guard port != 0 else {
            let code = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        Thread.detachNewThread { [self] in acceptLoop(fd) }
        return port
    }

    /// Ends every loop within a poll interval; the sockets are closed by the threads that own them.
    func stop() {
        locked { stopping = true }
    }

    private func acceptLoop(_ listener: Int32) {
        defer { close(listener) }
        while !isStopping {
            var p = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, 100)
            if ready < 0 && errno != EINTR { return }
            if ready <= 0 { continue }
            let fd = accept(listener, nil, nil)
            if fd < 0 { continue }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            locked { accepted += 1 }
            Thread.detachNewThread { [self] in serve(fd) }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        guard let path = readRequestPath(fd) else { return }
        locked { requests += 1 }
        if path.hasPrefix("/warmup") {
            sendAll(fd, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        guard sendAll(fd, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 1000000\r\n\r\n") else { return }
        // Every interval: if the client has hung up say so, otherwise send one more byte.
        while !isStopping {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, Int32(byteInterval * 1000))
            if ready < 0 && errno == EINTR { continue }
            if ready < 0 { return clientClosed() }
            if ready > 0 {
                var scratch: UInt8 = 0
                if recv(fd, &scratch, 1, 0) <= 0 { return clientClosed() } // end of stream or reset: the client hung up
                continue
            }
            if !sendAll(fd, "x") { return clientClosed() }
            locked { sent += 1 }
        }
    }

    /// The request target from the request line, once the whole head (up to the blank line) has arrived.
    private func readRequestPath(_ fd: Int32) -> String? {
        var head = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let blank = Data("\r\n\r\n".utf8)
        let giveUp = Date().addingTimeInterval(10)
        while head.range(of: blank) == nil {
            if head.count > 65_536 || Date() > giveUp || isStopping { return nil }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, 100)
            if ready < 0 && errno != EINTR { return nil }
            if ready <= 0 { continue }
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { return nil }
            head.append(contentsOf: chunk[0..<n])
        }
        let requestLine = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        return parts.count >= 2 ? String(parts[1]) : nil
    }

    @discardableResult
    private func sendAll(_ fd: Int32, _ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }

    private func clientClosed() {
        let first = locked { () -> Bool in
            let first = !reportedClose
            reportedClose = true
            return first
        }
        if first { onClientClosed() }
    }
}
