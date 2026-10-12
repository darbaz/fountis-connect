package org.fountis.connect

import java.io.IOException
import java.io.InputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The real ApiClient (HttpURLConnection) against a fake FOUNTIS server on localhost that is silent, or sends the response
 * one byte at a time forever. The per-read limit is 20 s, so only the overall deadline can end these within the test.
 */
class ApiClientDeadlineTest {
    enum class Mode { Silent, Trickle, Json }

    /** A tiny HTTP server on a loopback port. It reads the request, then behaves as [mode] says. */
    private class FakeServer : AutoCloseable {
        @Volatile var mode = Mode.Silent
        @Volatile var status = 200
        @Volatile var body = "{}"

        /** Bytes written by the trickle mode; stops growing once the client has closed the connection. */
        val trickled = AtomicInteger()

        @Volatile private var closed = false
        private val release = CountDownLatch(1)
        private val sockets = CopyOnWriteArrayList<Socket>()
        private val listener = ServerSocket(0, 50, InetAddress.getLoopbackAddress())

        val base: String get() = "http://127.0.0.1:${listener.localPort}/v1"

        init {
            thread(isDaemon = true, name = "fake-fountis-accept") {
                try {
                    while (!closed) {
                        val s = listener.accept()
                        sockets.add(s)
                        thread(isDaemon = true, name = "fake-fountis-conn") { serve(s) }
                    }
                } catch (_: IOException) {
                    // closed
                }
            }
        }

        private fun readLine(input: InputStream): String? {
            val sb = StringBuilder()
            while (true) {
                val c = input.read()
                if (c < 0) return null
                if (c == '\n'.code) return sb.toString().trimEnd('\r')
                sb.append(c.toChar())
            }
        }

        private fun serve(s: Socket) {
            try {
                val input = s.getInputStream()
                var contentLength = 0
                while (true) {
                    val line = readLine(input) ?: return
                    if (line.isEmpty()) break
                    if (line.startsWith("Content-Length:", ignoreCase = true)) contentLength = line.substring(15).trim().toInt()
                }
                repeat(contentLength) { input.read() }
                val out = s.getOutputStream()
                when (mode) {
                    Mode.Silent -> release.await() // never answers; close() lets go
                    Mode.Trickle -> {
                        out.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n".toByteArray())
                        out.flush()
                        // One byte every 20 ms, forever: every read returns in time, so no per-read limit ever fires.
                        while (!closed) {
                            out.write("1\r\n \r\n".toByteArray())
                            out.flush()
                            trickled.incrementAndGet()
                            Thread.sleep(20)
                        }
                    }
                    Mode.Json -> {
                        val bytes = body.toByteArray()
                        out.write("HTTP/1.1 $status X\r\nContent-Type: application/json\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n".toByteArray())
                        out.write(bytes)
                        out.flush()
                    }
                }
            } catch (_: Exception) {
                // the client went away
            } finally {
                try {
                    s.close()
                } catch (_: IOException) {
                }
            }
        }

        override fun close() {
            closed = true
            release.countDown()
            try {
                listener.close()
            } catch (_: IOException) {
            }
            for (s in sockets) {
                try {
                    s.close()
                } catch (_: IOException) {
                }
            }
        }
    }

    private val server = FakeServer()

    @After
    fun tearDown() = server.close()

    private fun client(deadlineMs: Long) = ApiClient(server.base, "pk_test_x", deadlineMs)

    /** Runs [body] on the test thread, failing it (not hanging CI) after 8 s. Returns how long it took in ms. */
    private fun timed(body: suspend () -> Unit): Long {
        val started = System.nanoTime()
        runBlocking { withTimeout(8_000) { body() } }
        return (System.nanoTime() - started) / 1_000_000
    }

    private suspend fun failureOf(block: suspend () -> Unit): Throwable? = try {
        block()
        null
    } catch (t: Throwable) {
        t
    }

    /** True once the trickle count stops growing, which means the client closed its end of the connection. */
    private fun awaitTrickleStops(): Boolean {
        repeat(20) {
            val before = server.trickled.get()
            Thread.sleep(300)
            if (server.trickled.get() == before) return true
        }
        return false
    }

    @Test
    fun aServerThatTricklesBytesIsCutOffAtTheDeadline() {
        server.mode = Mode.Trickle
        var e: Throwable? = null
        val ms = timed { e = failureOf { client(400).consent("tok") } }
        assertTrue("expected the deadline failure, got $e", e is RequestTimeoutException)
        assertTrue("expected a SocketTimeoutException like a read timeout, got $e", e is SocketTimeoutException)
        assertTrue("ended after $ms ms, before the 400 ms deadline", ms >= 350)
        assertTrue("ended after $ms ms, long after the deadline", ms < 4_000)
        assertTrue("the server should have been trickling (${server.trickled.get()} bytes)", server.trickled.get() >= 5)
        assertTrue("the client should have closed the connection", awaitTrickleStops())
    }

    @Test
    fun aServerThatNeverAnswersIsCutOffAtTheDeadline() {
        server.mode = Mode.Silent
        var e: Throwable? = null
        val ms = timed { e = failureOf { client(400).surveys("en") } }
        assertTrue("expected the deadline failure, got $e", e is RequestTimeoutException)
        assertTrue("ended after $ms ms, long after the deadline", ms < 4_000)
    }

    @Test
    fun theNextRequestWorksNormallyAfterATimeout() {
        val api = client(400)
        server.mode = Mode.Trickle
        var first: Throwable? = null
        timed { first = failureOf { api.consent("tok") } }
        assertTrue("got $first", first is RequestTimeoutException)

        server.mode = Mode.Json
        server.body = """{"stop":null,"ok":true}"""
        var ok = false
        timed { ok = api.putAnswer("q1", "a", "tok").optBoolean("ok") }
        assertTrue("the second request should succeed", ok)
    }

    @Test
    fun aFastAnswerIsUnaffectedByTheDeadline() {
        server.mode = Mode.Json
        server.body = """{"ok":true}"""
        var ok = false
        val ms = timed { ok = client(5_000).putAnswer("q1", "a", "tok").optBoolean("ok") }
        assertTrue(ok)
        assertTrue("took $ms ms", ms < 4_000)
    }

    @Test
    fun anErrorStatusStillBecomesAnApiError() {
        server.mode = Mode.Json
        server.status = 409
        server.body = """{"error":"already_taken","message":"nope"}"""
        var e: Throwable? = null
        timed { e = failureOf { client(5_000).consent("tok") } }
        assertTrue("expected an ApiError, got $e", e is ApiError)
        val api = e as ApiError
        assertEquals(409, api.status)
        assertEquals("already_taken", api.code)
        assertTrue(api.isFatal)
    }

    @Test
    fun theBestEffortEventCallSwallowsTheTimeout() {
        server.mode = Mode.Trickle
        val ms = timed { client(400).event("offer1", "shown") } // must return, not throw
        assertTrue("took $ms ms", ms < 4_000)
    }

    @Test
    fun cancellingTheCallerReleasesItWithoutWaitingForTheServer() {
        server.mode = Mode.Trickle
        val api = client(60_000)
        var outcome: Throwable? = null
        timed {
            val job = CoroutineScope(Dispatchers.Default).launch {
                try {
                    api.consent("tok")
                } catch (t: Throwable) {
                    outcome = t
                }
            }
            while (server.trickled.get() < 3) delay(10) // the request is really in flight
            job.cancel()
            withTimeout(1_000) { job.join() }
        }
        assertTrue("the caller should have been cancelled, got $outcome", outcome is CancellationException)
        assertTrue("the client should have closed the connection", awaitTrickleStops())
    }
}
