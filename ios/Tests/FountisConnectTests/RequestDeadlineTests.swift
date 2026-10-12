import XCTest
@testable import FountisConnect

/// `runWithinDeadline` is what bounds one API request in total. Deadlines here are fractions of a second so the suite
/// stays fast; production uses `requestDeadline` (15 s).
final class RequestDeadlineTests: XCTestCase {
    private struct Boom: Error, Equatable {}

    /// Work that never finishes and ignores cancellation, until a test lets it go (so nothing leaks when the test ends).
    private final class Stuck: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<String, Never>?
        private var early: String?

        func park() async -> String {
            await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
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

        func release(_ value: String) {
            lock.lock()
            let c = cont
            cont = nil
            if c == nil { early = value }
            lock.unlock()
            c?.resume(returning: value)
        }
    }

    // MARK: constants

    /// The contract says every platform ends a request after 15 s in total, and the two other waits stay at 10 s.
    func testTheDeadlineIsFifteenSecondsAndTheOtherWaitsAreUnchanged() {
        XCTAssertEqual(requestDeadline, 15)
        XCTAssertEqual(tokenProviderTimeout, 10)
        XCTAssertEqual(sheetAppearTimeout, 10)
    }

    func testTheClientUsesTheDeadlineForEveryTimeoutItSets() {
        let client = ApiClient(base: URL(string: "https://connect.test/v1")!, key: "pk_test_x")
        XCTAssertEqual(client.deadline, 15)
        XCTAssertEqual(client.session.configuration.timeoutIntervalForRequest, 15)
        XCTAssertEqual(client.session.configuration.timeoutIntervalForResource, 15, "was 30 s before the 15 s total deadline")
    }

    // MARK: results

    func testReturnsWhatTheWorkReturns() async throws {
        let value = try await runWithinDeadline(2) { "done" }
        XCTAssertEqual(value, "done")
    }

    func testSlowWorkThatBeatsTheDeadlineStillWins() async throws {
        let value = try await runWithinDeadline(2) {
            try await Task.sleep(nanoseconds: 50_000_000)
            return "slow but fine"
        }
        XCTAssertEqual(value, "slow but fine")
    }

    func testAnErrorFromTheWorkPropagatesAndIsNotATimeout() async {
        do {
            _ = try await runWithinDeadline(2) { () async throws -> String in throw Boom() }
            XCTFail("expected the work's error")
        } catch let e as Boom {
            XCTAssertEqual(e, Boom())
        } catch {
            XCTFail("expected Boom, got \(error)")
        }
    }

    // MARK: past the deadline

    func testWorkThatIsStillRunningAtTheDeadlineEndsAsATimeoutAndIsCancelled() async {
        let sawCancellation = expectation(description: "the work was told to stop")
        let started = Date()
        do {
            _ = try await runWithinDeadline(0.3) { () async throws -> String in
                // Cancellation-aware, like URLSession's async API: Task.sleep throws as soon as it is cancelled.
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch {
                    sawCancellation.fulfill()
                    throw error
                }
                return "never"
            }
            XCTFail("expected a timeout")
        } catch let e as URLError {
            XCTAssertEqual(e.code, .timedOut, "the same error URLSession raises for a timeout")
        } catch {
            XCTFail("expected URLError.timedOut, got \(error)")
        }
        let took = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(took, 0.25, "must not give up before the deadline")
        XCTAssertLessThan(took, 3)
        await fulfillment(of: [sawCancellation], timeout: 2)
    }

    func testWorkThatIgnoresCancellationDoesNotHoldTheCallerPastTheDeadline() async {
        let stuck = Stuck()
        let workReturned = expectation(description: "the abandoned work ran to the end")
        let started = Date()
        do {
            _ = try await runWithinDeadline(0.3) { () async throws -> String in
                let v = await stuck.park() // only an answer gets it out, like blocking code that cannot be cancelled
                workReturned.fulfill()
                return v
            }
            XCTFail("expected a timeout")
        } catch let e as URLError {
            XCTAssertEqual(e.code, .timedOut)
        } catch {
            XCTFail("expected URLError.timedOut, got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "the call must not wait for work that ignores cancellation")

        // The work finally ends, long after the caller gave up: nothing resumes twice, nothing crashes.
        stuck.release("late")
        await fulfillment(of: [workReturned], timeout: 2)
    }

    // MARK: caller cancellation

    func testCancellingTheCallerEndsTheCallPromptlyAndCancelsTheWork() async {
        let sawCancellation = expectation(description: "the work was told to stop")
        let task = Task<String, Error> {
            try await runWithinDeadline(30) { () async throws -> String in
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch {
                    sawCancellation.fulfill()
                    throw error
                }
                return "never"
            }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let started = Date()
        task.cancel()
        let result = await task.result
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "cancellation must not wait for the work or the deadline")
        switch result {
        case .success(let v): XCTFail("expected CancellationError, got \(v)")
        case .failure(let e): XCTAssertTrue(e is CancellationError, "expected CancellationError, got \(e)")
        }
        await fulfillment(of: [sawCancellation], timeout: 2)
    }

    func testACallerThatIsAlreadyCancelledEndsAtOnce() async {
        let stuck = Stuck()
        let task = Task<String, Error> {
            while !Task.isCancelled { await Task.yield() } // enter runWithinDeadline already cancelled
            return try await runWithinDeadline(30) { await stuck.park() }
        }
        task.cancel()
        let started = Date()
        let result = await task.result
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        switch result {
        case .success(let v): XCTFail("expected CancellationError, got \(v)")
        case .failure(let e): XCTAssertTrue(e is CancellationError, "expected CancellationError, got \(e)")
        }
        stuck.release("done") // let the abandoned work finish
    }
}
