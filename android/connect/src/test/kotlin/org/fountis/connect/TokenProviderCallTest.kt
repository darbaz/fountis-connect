package org.fountis.connect

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.coroutines.suspendCoroutine
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** callTokenProvider: a provider that never settles must not wedge the caller, and must not look like a cancellation. */
class TokenProviderCallTest {
    /** Stands in for Core.scope: a SupervisorJob scope, so a failing provider stays in its Deferred. */
    private val scope = CoroutineScope(SupervisorJob())

    /** Counted down in @After so blocking providers do not leave pool threads parked after the test. */
    private val release = CountDownLatch(1)

    @After
    fun tearDown() {
        release.countDown()
        scope.cancel()
    }

    /** Runs [body] on the test thread, failing it (not hanging CI) after 5 s, and asserts it took under 2 s. */
    private fun bounded(body: suspend CoroutineScope.() -> Unit) {
        val started = System.nanoTime()
        runBlocking { withTimeout(5_000) { body(this) } }
        val ms = (System.nanoTime() - started) / 1_000_000
        assertTrue("took $ms ms", ms < 2_000)
    }

    /** What [block] threw, or null if it returned. */
    private suspend fun failureOf(block: suspend () -> Unit): Throwable? = try {
        block()
        null
    } catch (t: Throwable) {
        t
    }

    @Test
    fun returnsTheToken() = bounded {
        assertEquals("tok", callTokenProvider(scope, 1_000) { "tok" })
    }

    @Test
    fun returnsNullWhenNobodyIsSignedIn() = bounded {
        assertNull(callTokenProvider(scope, 1_000) { null })
    }

    @Test
    fun aThrowingProviderPropagatesItsOwnException() = bounded {
        val e = failureOf { callTokenProvider(scope, 1_000) { throw IllegalStateException("boom") } }
        assertTrue("got $e", e is IllegalStateException)
        assertEquals("boom", e!!.message)
    }

    @Test
    fun aBlockingProviderTimesOutAsAPlainException() = bounded {
        val e = failureOf {
            callTokenProvider(scope, 200) {
                release.await() // a blocking Java provider: cancelling its coroutine cannot interrupt it
                "late"
            }
        }
        assertTrue("got $e", e is TokenProviderTimeoutException)
        assertTrue("must not be a CancellationException", e !is CancellationException)
    }

    @Test
    fun aProviderThatNeverResumesTimesOut() = bounded {
        val e = failureOf {
            callTokenProvider(scope, 200) {
                suspendCoroutine<String?> { /* never resumed, and not cancellable */ }
            }
        }
        assertTrue("got $e", e is TokenProviderTimeoutException)
        assertTrue("must not be a CancellationException", e !is CancellationException)
    }

    @Test
    fun aCooperativeProviderIsCancelledWhenTheCallGivesUp() = bounded {
        val cancelled = CountDownLatch(1)
        val e = failureOf {
            callTokenProvider(scope, 200) {
                try {
                    delay(60_000)
                    "late"
                } finally {
                    cancelled.countDown()
                }
            }
        }
        assertTrue("got $e", e is TokenProviderTimeoutException)
        assertTrue("the provider should have been cancelled", cancelled.await(1, TimeUnit.SECONDS))
    }

    @Test
    fun aProviderThatCancelsItselfIsAFailureNotACancellation() = bounded {
        val e = failureOf { callTokenProvider(scope, 1_000) { throw CancellationException("own") } }
        assertTrue("got $e", e is TokenProviderFailedException)
        assertTrue("must not be a CancellationException", e !is CancellationException)
        assertTrue("cause should be the provider's cancellation", e!!.cause is CancellationException)
    }

    @Test
    fun cancellingTheCallerStillCancelsTheCaller() = bounded {
        val providerStarted = CompletableDeferred<Unit>()
        val outcome = CompletableDeferred<Throwable?>()
        val caller = launch(Dispatchers.Default) {
            try {
                callTokenProvider(scope, 60_000) {
                    providerStarted.complete(Unit)
                    suspendCoroutine<String?> { /* never answers */ }
                }
                outcome.complete(null)
            } catch (t: Throwable) {
                outcome.complete(t)
            }
        }
        providerStarted.await()
        caller.cancel()
        val e = withTimeout(1_000) { outcome.await() }
        assertTrue("cancellation must propagate to the caller, got $e", e is CancellationException)
    }

    @Test
    fun anEmptyStringIsNotATokenAndNotSignedOut() {
        // openSession turns "" into NoFill (it only takes the guest path for null); decode must agree it is unusable.
        assertNull(TokenInfo.decode(""))
    }
}
