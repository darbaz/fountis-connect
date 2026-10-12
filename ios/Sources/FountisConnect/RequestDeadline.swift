import Foundation

/// The most one API request may take in total: opening the connection, sending the request and reading the whole
/// response body. The web and Android SDKs end a request at the same 15 s.
///
/// URLSession alone cannot promise that. `timeoutIntervalForRequest` is an idle timeout (it restarts whenever bytes
/// arrive), so a server that sends a byte now and then keeps a request open forever. `timeoutIntervalForResource` does
/// bound the whole transfer, and `ApiClient` sets it, but the deadline below does not depend on it: it is the SDK's own.
let requestDeadline: TimeInterval = 15

/// Runs `work` (one HTTP exchange) but never waits on it for longer than `deadline` seconds, whatever it is doing.
///
/// After `deadline` this throws `URLError(.timedOut)`, the error URLSession itself raises for a timeout, so every
/// caller already treats it as an ordinary network failure (the study ends as `noFill`, `event()` swallows it, the
/// engine's own retry takes over for in-study calls). `work` is cancelled at that point, which makes URLSession cancel
/// the task and close the connection.
///
/// Deliberately not a task group, like `callTokenProvider`: a group waits for all its children, so work that is slow
/// to react to cancellation would keep the caller waiting. Instead `work` and a timer run as unstructured tasks, the
/// first to finish settles a one-shot continuation, and a late outcome from `work` is dropped. Cancelling the caller
/// ends the call at once with `CancellationError` and cancels `work`.
func runWithinDeadline<T: Sendable>(
    _ deadline: TimeInterval,
    _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    let call = DeadlineCall<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            // Already cancelled (or timed out, which cannot happen yet): attach resumes `cont` with that outcome.
            guard call.attach(cont) else { return }
            call.track(Task {
                do { call.settle(.success(try await work())) } catch { call.settle(.failure(error)) }
            })
            call.track(Task {
                do { try await Task.sleep(nanoseconds: UInt64(max(deadline, 0) * 1_000_000_000)) } catch { return }
                call.settle(.failure(URLError(.timedOut)))
            })
        }
    } onCancel: {
        call.settle(.failure(CancellationError()))
    }
}

/// The one-shot state of a single `runWithinDeadline`: the continuation is resumed exactly once, by whichever of the
/// work, the timer or a cancellation settles first. Everything is guarded by one lock because those three race on
/// different threads.
private final class DeadlineCall<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var outcome: Result<T, Error>?
    private var tasks: [Task<Void, Never>] = []

    /// Stores the continuation. Returns `false` (after resuming it) when the call was already settled, which only a
    /// cancellation that arrived before the continuation existed can have done.
    func attach(_ cont: CheckedContinuation<T, Error>) -> Bool {
        lock.lock()
        if let done = outcome {
            lock.unlock()
            cont.resume(with: done)
            return false
        }
        continuation = cont
        lock.unlock()
        return true
    }

    /// Keeps a task so settling can cancel it; cancels it at once if the call is already settled.
    func track(_ task: Task<Void, Never>) {
        lock.lock()
        if outcome == nil {
            tasks.append(task)
            lock.unlock()
        } else {
            lock.unlock()
            task.cancel()
        }
    }

    /// First caller wins; later calls (a late answer from the work, a timer that lost the race) do nothing. Cancels
    /// both tasks: the timer when the work won, the work when the timer or the caller won.
    func settle(_ result: Result<T, Error>) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = result
        let cont = continuation
        continuation = nil
        let running = tasks
        tasks = []
        lock.unlock()
        running.forEach { $0.cancel() }
        cont?.resume(with: result)
    }
}
