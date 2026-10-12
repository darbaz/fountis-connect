package org.fountis.connect

import java.io.IOException
import java.net.SocketTimeoutException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** callWithinDeadline: a source that is slow, silent or keeps trickling must not hold the caller past the deadline. */
class RequestDeadlineTest {
    /** Stands in for ApiClient's scope: a SupervisorJob scope on the IO dispatcher, so blocking work is allowed. */
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** Counted down in @After so blocking sources do not leave pool threads parked after the test. */
    private val release = CountDownLatch(1)

    private val abandoned = CountDownLatch(1)
    private val abandonCalls = AtomicInteger()
    private val abandon: () -> Unit = {
        abandonCalls.incrementAndGet()
        abandoned.countDown()
    }

    @After
    fun tearDown() {
        release.countDown()
        scope.cancel()
    }

    /**
     * Runs [body] on the test thread, failing it (not hanging CI) after 5 s, and asserts it took under 4 s. Every
     * deadline used here is 60 s at most and mostly 100-300 ms, so 4 s still proves nothing waited for a deadline;
     * the margin is for a cold JVM (class loading, the IO pool starting) on a busy CI runner.
     */
    private fun bounded(body: suspend CoroutineScope.() -> Unit) {
        val started = System.nanoTime()
        runBlocking { withTimeout(5_000) { body(this) } }
        val ms = (System.nanoTime() - started) / 1_000_000
        assertTrue("took $ms ms", ms < 4_000)
    }

    /**
     * True when [actual] is [expected] itself, or the copy kotlinx.coroutines hands back in its place. With assertions on
     * (as under Gradle's test task) `await()` rethrows a failure as a fresh instance of the same class and message that
     * has the original as its cause, to keep the stack trace useful, so `assertSame` cannot be used on it.
     */
    private fun isOrCopyOf(expected: Throwable, actual: Throwable?): Boolean {
        if (actual == null || actual.javaClass != expected.javaClass || actual.message != expected.message) return false
        var t: Throwable? = actual
        var depth = 0
        while (t != null && depth++ < 10) {
            if (t === expected) return true
            t = t.cause
        }
        return false
    }

    /** What [block] threw, or null if it returned. */
    private suspend fun failureOf(block: suspend () -> Unit): Throwable? = try {
        block()
        null
    } catch (t: Throwable) {
        t
    }

    @Test
    fun returnsTheResultOfAFastBlock() = bounded {
        assertEquals("ok", callWithinDeadline(scope, 1_000, abandon) { "ok" })
        assertEquals(0, abandonCalls.get())
    }

    @Test
    fun aNullResultIsNotATimeout() = bounded {
        assertNull(callWithinDeadline<String?>(scope, 1_000, abandon) { null })
    }

    @Test
    fun aSilentSourceTimesOutAndIsAbandoned() = bounded {
        val e = failureOf {
            callWithinDeadline(scope, 200, abandon) {
                release.await() // a blocking read that gets no bytes: cancelling its coroutine cannot interrupt it
                "late"
            }
        }
        assertTrue("got $e", e is RequestTimeoutException)
        assertTrue("abandon should have been called", abandoned.await(1, TimeUnit.SECONDS))
    }

    /** What a per-read timeout cannot catch: every read returns in time, yet the response never ends. */
    @Test
    fun aSourceThatKeepsTricklingStillTimesOut() {
        val stop = AtomicBoolean(false)
        val pieces = AtomicInteger()
        val ended = CountDownLatch(1)
        val started = System.nanoTime()
        var e: Throwable? = null
        runBlocking {
            withTimeout(5_000) {
                e = failureOf {
                    callWithinDeadline<String>(scope, 300, { stop.set(true); abandon() }) {
                        try {
                            while (!stop.get()) { // one piece every 10 ms, so a 1 s per-read limit would never fire
                                Thread.sleep(10)
                                pieces.incrementAndGet()
                            }
                            throw IOException("abandoned")
                        } finally {
                            ended.countDown()
                        }
                    }
                }
            }
        }
        val ms = (System.nanoTime() - started) / 1_000_000
        assertTrue("got $e", e is RequestTimeoutException)
        assertTrue("gave up after $ms ms, before the deadline", ms >= 250)
        assertTrue("gave up after $ms ms, long after the deadline", ms < 4_000)
        assertTrue("the source should have been trickling (${pieces.get()} pieces)", pieces.get() >= 5)
        assertTrue("abandoning should stop the source", ended.await(1, TimeUnit.SECONDS))
    }

    @Test
    fun theTimeoutIsTheSameKindOfFailureAsAReadTimeout() = bounded {
        val e = failureOf { callWithinDeadline(scope, 100, abandon) { release.await(); "late" } }
        assertTrue("a SocketTimeoutException, like a read timeout (got $e)", e is SocketTimeoutException)
        assertTrue("an IOException, so event() swallows it (got $e)", e is IOException)
        assertFalse("must not be a CancellationException", e is CancellationException)
    }

    @Test
    fun aFailureInTimeIsPassedOnUnchanged() = bounded {
        val io = IOException("connection reset")
        val e1 = failureOf { callWithinDeadline<String>(scope, 1_000, abandon) { throw io } }
        assertTrue("the IOException should come out as it went in, got $e1", isOrCopyOf(io, e1))

        val api = ApiError(401, "invalid_token", "no")
        val e2 = failureOf { callWithinDeadline<String>(scope, 1_000, abandon) { throw api } }
        assertTrue("the ApiError should come out as it went in, got $e2", isOrCopyOf(api, e2))

        assertEquals(0, abandonCalls.get())
    }

    @Test
    fun aBrokenAbandonDoesNotChangeTheOutcome() = bounded {
        val e = failureOf {
            callWithinDeadline(scope, 100, { throw IllegalStateException("cannot close") }) { release.await(); "late" }
        }
        assertTrue("got $e", e is RequestTimeoutException)
    }

    @Test
    fun cancellingTheCallerReleasesItAndAbandons() = bounded {
        val blockStarted = CompletableDeferred<Unit>()
        val outcome = CompletableDeferred<Throwable?>()
        val caller = launch(Dispatchers.Default) {
            try {
                callWithinDeadline(scope, 60_000, abandon) {
                    blockStarted.complete(Unit)
                    release.await()
                    "never"
                }
                outcome.complete(null)
            } catch (t: Throwable) {
                outcome.complete(t)
            }
        }
        blockStarted.await()
        caller.cancel()
        val e = withTimeout(1_000) { outcome.await() }
        assertTrue("cancellation must propagate to the caller, got $e", e is CancellationException)
        assertTrue("abandon should have been called", abandoned.await(1, TimeUnit.SECONDS))
    }
}
