import XCTest
@testable import FountisConnect

/// `callTokenProvider` is what keeps a partner's token provider from wedging the SDK. Timeouts here are fractions of a
/// second so the suite stays fast; production uses `tokenProviderTimeout` (10 s).
final class TokenProviderTests: XCTestCase {
    private struct Boom: Error, Equatable {}

    /// Holds the continuation of a provider that never answers and ignores cancellation, so a test can answer late
    /// (and so nothing leaks when it ends). Answering before the provider has parked is remembered.
    private final class Parked: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<String?, Never>?
        private var early: String??

        func park() async -> String? {
            await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
                lock.lock()
                if let value = early {
                    lock.unlock()
                    c.resume(returning: value)
                } else {
                    cont = c
                    lock.unlock()
                }
            }
        }

        func answer(_ value: String?) {
            lock.lock()
            let c = cont
            cont = nil
            if c == nil { early = .some(value) }
            lock.unlock()
            c?.resume(returning: value)
        }
    }

    // MARK: results

    func testReturnsTheProvidersToken() async throws {
        let token = try await callTokenProvider({ "a.b.c" }, timeout: 0.2)
        XCTAssertEqual(token, "a.b.c")
    }

    func testReturnsNilWhenTheProviderReturnsNil() async throws {
        let token = try await callTokenProvider({ nil }, timeout: 0.2)
        XCTAssertNil(token)
    }

    func testASlowProviderThatBeatsTheTimeoutStillWins() async throws {
        let token = try await callTokenProvider({
            try await Task.sleep(nanoseconds: 50_000_000)
            return "slow.but.fine"
        }, timeout: 2)
        XCTAssertEqual(token, "slow.but.fine")
    }

    func testAThrowingProvidersErrorPropagatesAndIsNotATimeout() async {
        do {
            _ = try await callTokenProvider({ throw Boom() }, timeout: 0.2)
            XCTFail("expected the provider's error")
        } catch let e as Boom {
            XCTAssertEqual(e, Boom())
        } catch {
            XCTFail("expected Boom, got \(error)")
        }
    }

    // MARK: never answers

    func testAProviderThatNeverAnswersAndIgnoresCancellationTimesOut() async {
        let parked = Parked()
        let providerReturned = expectation(description: "provider ran to the end")
        let started = Date()
        do {
            _ = try await callTokenProvider({
                let v = await parked.park() // not cancellation-aware: only an answer gets it out
                providerReturned.fulfill()
                return v
            }, timeout: 0.2)
            XCTFail("expected TokenProviderTimeout")
        } catch is TokenProviderTimeout {
            // expected
        } catch {
            XCTFail("expected TokenProviderTimeout, got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the call must not wait for a provider that ignores cancellation")

        // The provider finally answers, long after the caller gave up: nothing resumes twice, nothing crashes.
        parked.answer("late.token.x")
        await fulfillment(of: [providerReturned], timeout: 2)
    }

    // MARK: caller cancellation

    func testCancellingTheCallerEndsTheCallPromptly() async {
        let parked = Parked()
        let task = Task<String?, Error> {
            try await callTokenProvider({ await parked.park() }, timeout: 30)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let started = Date()
        task.cancel()
        let result = await task.result
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "cancellation must not wait for the provider or the timeout")
        switch result {
        case .success(let t): XCTFail("expected CancellationError, got token \(String(describing: t))")
        case .failure(let e): XCTAssertTrue(e is CancellationError, "expected CancellationError, got \(e)")
        }
        parked.answer(nil) // let the abandoned provider finish
    }

    func testACallerThatIsAlreadyCancelledEndsAtOnce() async {
        let parked = Parked()
        let task = Task<String?, Error> {
            while !Task.isCancelled { await Task.yield() } // enter callTokenProvider already cancelled
            return try await callTokenProvider({ await parked.park() }, timeout: 30)
        }
        task.cancel()
        let started = Date()
        let result = await task.result
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        switch result {
        case .success(let t): XCTFail("expected CancellationError, got token \(String(describing: t))")
        case .failure(let e): XCTAssertTrue(e is CancellationError, "expected CancellationError, got \(e)")
        }
        parked.answer(nil)
    }

    // MARK: what counts as a token

    /// An empty string is neither a token nor "signed out": `openSession` turns it into `noFill`, not the guest path.
    func testAnEmptyStringIsNotAToken() {
        XCTAssertNil(TokenInfo.decode(""))
        XCTAssertNotNil(TokenInfo.decode("h.eyJzdWIiOiJ1MSJ9.s"), "sanity: a well-formed token still decodes")
    }
}
