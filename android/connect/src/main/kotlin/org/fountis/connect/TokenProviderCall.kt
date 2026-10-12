package org.fountis.connect

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withTimeoutOrNull

/** How long the host's token provider may take to answer. The React Native and Flutter wrappers use the same 10 s. */
internal const val TOKEN_PROVIDER_TIMEOUT_MS: Long = 10_000L

/**
 * The token provider did not answer in time. A plain [Exception] on purpose, never a [CancellationException]: the SDK
 * rethrows cancellation into the host's coroutine, and a slow provider must not look like the host being cancelled.
 */
internal class TokenProviderTimeoutException : Exception("the token provider did not answer in time")

/**
 * The token provider ended by cancelling itself (for example its own `withTimeout` fired and threw a
 * `TimeoutCancellationException`) while the caller was still active. A plain failure, never a [CancellationException].
 */
internal class TokenProviderFailedException(cause: Throwable) : Exception("the token provider was cancelled", cause)

private class Answer(val token: String?)

/**
 * Asks the host's token provider for the signed user token, giving up after [timeoutMs].
 *
 * Why not `withTimeout { withContext(Dispatchers.IO) { provider() } }`: `withContext` waits for its block, and a
 * blocking Java provider (or a suspension that ignores cancellation) cannot be cancelled, so the call would still
 * hang and keep `Core.presenting` set for the rest of the process, turning every later run into `NoFill`. And
 * `withTimeout` throws `TimeoutCancellationException`, a [CancellationException] the SDK would then rethrow into the
 * host's coroutine.
 *
 * Instead the provider runs in its own coroutine in [scope] (which must have a `SupervisorJob`, so a failing provider
 * stays in the `Deferred` and cannot cancel the scope). That coroutine is not a child of the caller, so the caller can
 * stop waiting even if the provider never cooperates. The provider is cancelled when we give up, which only helps a
 * cooperative one; a blocking one keeps its thread until it returns, but nothing waits for it any more.
 *
 * Returns the token, or `null` when the provider answered `null` (nobody is signed in).
 *
 * Throws:
 * - [TokenProviderTimeoutException] when there was no answer within [timeoutMs]. That is a failure, never "signed
 *   out": the caller must show nothing and must not take the guest path.
 * - [TokenProviderFailedException] when the provider threw a [CancellationException] of its own.
 * - Whatever else the provider threw, unchanged.
 * - A [CancellationException] only when the caller itself was cancelled, so cancellation propagates as usual.
 */
internal suspend fun callTokenProvider(
    scope: CoroutineScope,
    timeoutMs: Long = TOKEN_PROVIDER_TIMEOUT_MS,
    provider: suspend () -> String?,
): String? {
    val call = scope.async(Dispatchers.IO) { provider() }
    // Answer(...) so a legitimate null answer is told apart from withTimeoutOrNull's null on timeout.
    val answer = try {
        withTimeoutOrNull(timeoutMs) { Answer(call.await()) }
    } catch (e: CancellationException) {
        call.cancel()
        // The caller was cancelled: rethrow, and cancellation propagates as before.
        currentCoroutineContext().ensureActive()
        // Otherwise it was the provider (or the scope) that cancelled: an ordinary failure for the SDK.
        throw TokenProviderFailedException(e)
    }
    if (answer == null) {
        call.cancel()
        throw TokenProviderTimeoutException()
    }
    return answer.token
}
