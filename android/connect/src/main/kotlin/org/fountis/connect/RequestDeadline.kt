package org.fountis.connect

import java.net.SocketTimeoutException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * The most one API request may take in total: opening the connection, sending the request and reading the whole
 * response body. The web SDK aborts at the same 15 s. The HTTP client's own limits (15 s to connect, 20 s per read)
 * are per step, so a server that keeps sending a byte at a time never trips them; this is the bound on the whole.
 */
internal const val REQUEST_DEADLINE_MS: Long = 15_000L

/**
 * A request that ran past its deadline. A [SocketTimeoutException] on purpose: it is what a read timeout throws, so
 * every caller already treats it as an ordinary network failure (the study ends as noFill, `event()` swallows it).
 */
internal class RequestTimeoutException(timeoutMs: Long) :
    SocketTimeoutException("the request did not finish within $timeoutMs ms")

private class Done<T>(val value: T)

/**
 * Runs the blocking [block] (one HTTP exchange) and stops waiting for it after [timeoutMs], whatever it is doing.
 *
 * Why not `withTimeout { withContext(Dispatchers.IO) { block() } }`: `withContext` waits for its block, and blocking
 * socket code cannot be cancelled, so the caller would stay stuck behind a slow or trickling server. Instead the block
 * runs in its own coroutine in [scope], which the caller does not wait for once it gives up. [scope] must have a
 * `SupervisorJob` and a dispatcher that allows blocking calls (`Dispatchers.IO`).
 *
 * When the caller gives up (deadline passed, or the caller was cancelled) it also calls [abandon] on another thread,
 * so the exchange can close its socket and free the thread. [abandon] is best effort: the caller is already released.
 *
 * Throws:
 * - [RequestTimeoutException] when the block did not finish within [timeoutMs].
 * - Whatever the block threw, unchanged, when it failed in time.
 * - A [CancellationException] when the caller itself was cancelled.
 */
internal suspend fun <T> callWithinDeadline(
    scope: CoroutineScope,
    timeoutMs: Long,
    abandon: () -> Unit,
    block: () -> T,
): T {
    val call = scope.async { block() }
    // Done(...) so a legitimate null result is told apart from withTimeoutOrNull's null on timeout.
    val done = try {
        withTimeoutOrNull(timeoutMs) { Done(call.await()) }
    } catch (e: CancellationException) {
        // Only the caller can cancel here (the block never cancels itself, and nothing else cancels `call`).
        giveUp(scope, call, abandon)
        throw e
    }
    if (done == null) {
        giveUp(scope, call, abandon)
        throw RequestTimeoutException(timeoutMs)
    }
    return done.value
}

private fun giveUp(scope: CoroutineScope, call: Deferred<*>, abandon: () -> Unit) {
    call.cancel()
    // Off the caller's thread: closing a socket that another thread is reading may itself block on some JVMs.
    scope.launch {
        try {
            abandon()
        } catch (_: Throwable) {
        }
    }
}
