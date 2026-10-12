import Foundation

/// How long the SDK waits for the partner's token provider. Same 10 seconds as the React Native and Flutter wrappers.
let tokenProviderTimeout: TimeInterval = 10

/// The token provider did not answer in time. A failure, never "signed out": nothing is shown (`noFill`).
struct TokenProviderTimeout: Error {}

/// Calls the partner's token provider, but never waits on it for longer than `timeout` seconds.
///
/// A provider that never returns (a hung request, a lost continuation) must not wedge the SDK: `Core.runInner` holds
/// `presenting` for the whole call, so a call that never ends would turn every later show, auto-show, push and
/// notification tap into `noFill` for good. After `timeout` this throws `TokenProviderTimeout`, which the caller treats
/// as a failed check. It is never the guest path: only a provider that returns `nil` means nobody is signed in.
///
/// Deliberately not a task group: a group waits for all its children, so a provider that ignores cancellation would
/// still hang the call. Instead the provider and a timer run as unstructured tasks, the first to finish settles a
/// one-shot continuation, and a late answer from the provider is dropped. Cancelling the caller (for example
/// `signOut()` cancelling the auto-show task) ends the call at once with `CancellationError`.
func callTokenProvider(
    _ provider: @escaping () async throws -> String?,
    timeout: TimeInterval = tokenProviderTimeout
) async throws -> String? {
    let call = TokenCall()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String?, Error>) in
            // Already cancelled (or timed out, which cannot happen yet): attach resumes `cont` with that outcome.
            guard call.attach(cont) else { return }
            call.track(Task {
                do { call.settle(.success(try await provider())) } catch { call.settle(.failure(error)) }
            })
            call.track(Task {
                do { try await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000)) } catch { return }
                call.settle(.failure(TokenProviderTimeout()))
            })
        }
    } onCancel: {
        call.settle(.failure(CancellationError()))
    }
}

/// The one-shot state of a single `callTokenProvider`: the continuation is resumed exactly once, by whichever of the
/// provider, the timer or a cancellation settles first. Everything is guarded by one lock because those three race
/// on different threads.
private final class TokenCall: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Error>?
    private var outcome: Result<String?, Error>?
    private var tasks: [Task<Void, Never>] = []

    /// Stores the continuation. Returns `false` (after resuming it) when the call was already settled, which only a
    /// cancellation that arrived before the continuation existed can have done.
    func attach(_ cont: CheckedContinuation<String?, Error>) -> Bool {
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

    /// First caller wins; later calls (a late provider answer, a timer that lost the race) do nothing. Cancels both
    /// tasks: the timer when the provider won, the provider when the timer or the caller won.
    func settle(_ result: Result<String?, Error>) {
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
