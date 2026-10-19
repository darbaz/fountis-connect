package org.fountis.connect

import java.io.IOException
import java.io.InputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import kotlin.concurrent.thread
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guest attestation on the wire: the real ApiClient (HttpURLConnection) and GuestAttestation against a fake FOUNTIS
 * server on localhost that records every request, with a fake Play Integrity. Shows what FOUNTIS actually receives for
 * each attestation mode, and how a refusal ends.
 */
class AttestWireTest {
    private class Req(val method: String, val path: String, val headers: Map<String, String>, val body: String)

    /** A tiny HTTP server on a loopback port. [handler] answers (status to body), or returns null to never answer. */
    private class RecordingServer : AutoCloseable {
        @Volatile var handler: (Req) -> Pair<Int, String>? = { 200 to "{}" }
        val requests = CopyOnWriteArrayList<Req>()

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
                val parts = (readLine(input) ?: return).split(" ")
                val headers = HashMap<String, String>()
                while (true) {
                    val line = readLine(input) ?: return
                    if (line.isEmpty()) break
                    val i = line.indexOf(':')
                    if (i > 0) headers[line.substring(0, i).trim().lowercase()] = line.substring(i + 1).trim()
                }
                val length = headers["content-length"]?.toIntOrNull() ?: 0
                val bytes = ByteArray(length)
                var read = 0
                while (read < length) {
                    val n = input.read(bytes, read, length - read)
                    if (n < 0) break
                    read += n
                }
                val req = Req(parts[0], parts[1], headers, String(bytes, 0, read, Charsets.UTF_8))
                requests.add(req)
                val reply = handler(req)
                if (reply == null) {
                    release.await() // never answers; close() lets go
                    return
                }
                val payload = reply.second.toByteArray(Charsets.UTF_8)
                val out = s.getOutputStream()
                out.write("HTTP/1.1 ${reply.first} X\r\nContent-Type: application/json\r\nContent-Length: ${payload.size}\r\nConnection: close\r\n\r\n".toByteArray())
                out.write(payload)
                out.flush()
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

    /** A stand-in for Play Integrity. */
    private class FakeAttestor : Attestor {
        val prepared = CopyOnWriteArrayList<Long>()
        val hashes = CopyOnWriteArrayList<String>()

        @Volatile var prepareFailure: Throwable? = null

        val calls: Int get() = prepared.size + hashes.size

        override suspend fun prepare(cloudProjectNumber: Long) {
            prepared.add(cloudProjectNumber)
            prepareFailure?.let { throw it }
        }

        override suspend fun request(requestHash: String): String {
            hashes.add(requestHash)
            return "integrity-token"
        }
    }

    private val server = RecordingServer()
    private val scope = CoroutineScope(SupervisorJob())
    private val fake = FakeAttestor()

    /** One for the whole test, like the SDK's one per process: Play Integrity is prepared once however many sessions follow. */
    private val attestation = GuestAttestation(fake, scope)

    @After
    fun tearDown() {
        scope.cancel()
        server.close()
    }

    private fun route(guest: Pair<Int, String>? = 200 to """{"guest_session":"gs_1","expires_in":3600}""", challenge: Pair<Int, String>? = 200 to """{"challenge":"$CHALLENGE","expires_in":300}""") {
        server.handler = { r ->
            when (r.path) {
                "/v1/attest/challenge" -> challenge
                "/v1/guest/session" -> guest
                else -> 404 to """{"error":"not_found"}"""
            }
        }
    }

    private fun client() = ApiClient(server.base, "pk_test_x")

    /** Runs [body] on the test thread, failing it (not hanging CI) after 8 s. */
    private fun bounded(body: suspend () -> Unit) {
        runBlocking { withTimeout(8_000) { body() } }
    }

    /** What the SDK does right before it needs a guest session: attest (when asked), then ask for the session. */
    private suspend fun guestSessionFor(api: ApiClient, config: AttestConfig, attestation: GuestAttestation = this.attestation): String {
        val attest = attestation.attest(config, INSTALL) { api.attestChallenge() }
        return api.guestSession(INSTALL, attest)
    }

    private fun keysOf(o: JSONObject): Set<String> = o.keys().asSequence().toSet()

    private suspend fun failureOf(block: suspend () -> Unit): Throwable? = try {
        block()
        null
    } catch (t: Throwable) {
        t
    }

    // ---- the endpoints ----

    @Test
    fun theChallengeIsAPostWithTheKeyHeaderAndNoAttestObject() = bounded {
        route()
        assertEquals(CHALLENGE, client().attestChallenge())
        val r = server.requests.single()
        assertEquals("POST", r.method)
        assertEquals("/v1/attest/challenge", r.path)
        assertEquals("pk_test_x", r.headers["x-fountis-key"])
    }

    @Test
    fun aChallengeReplyWithoutAChallengeIsABadResponse() = bounded {
        route(challenge = 200 to "{}")
        val e = failureOf { client().attestChallenge() }
        assertTrue("got $e", e is ApiError)
        assertEquals("bad_response", (e as ApiError).code)
    }

    // ---- what FOUNTIS receives ----

    @Test
    fun modeOffSendsTheInstallIdAloneAndNeverCallsAnAttestEndpoint() = bounded {
        route()
        for (config in listOf(AttestConfig.OFF, AttestConfig("off", "123456789012"))) {
            assertEquals("gs_1", guestSessionFor(client(), config))
        }
        assertEquals(listOf("/v1/guest/session", "/v1/guest/session"), server.requests.map { it.path })
        for (r in server.requests) {
            assertEquals(setOf("install_id"), keysOf(JSONObject(r.body)))
            assertEquals(INSTALL, JSONObject(r.body).getString("install_id"))
        }
        assertEquals("Play Integrity was touched", 0, fake.calls)
    }

    @Test
    fun reportModeAsksForAChallengeThenSendsTheTokenAndTheRightRequestHash() = bounded {
        route()
        assertEquals("gs_1", guestSessionFor(client(), AttestConfig("report", "123456789012")))

        assertEquals(listOf("/v1/attest/challenge", "/v1/guest/session"), server.requests.map { it.path })
        val body = JSONObject(server.requests[1].body)
        assertEquals(setOf("install_id", "attest"), keysOf(body))
        assertEquals(INSTALL, body.getString("install_id"))
        val attest = body.getJSONObject("attest")
        assertEquals(setOf("platform", "token", "challenge"), keysOf(attest))
        assertEquals("android", attest.getString("platform"))
        assertEquals("integrity-token", attest.getString("token"))
        assertEquals(CHALLENGE, attest.getString("challenge"))

        assertEquals(listOf(123456789012L), fake.prepared.toList())
        assertEquals("the hash the token is bound to", listOf(EXPECTED_HASH), fake.hashes.toList())
    }

    @Test
    fun enforceModeSendsTheSameAttestObject() = bounded {
        route()
        guestSessionFor(client(), AttestConfig("enforce", "42"))
        val attest = JSONObject(server.requests.last().body).getJSONObject("attest")
        assertEquals("integrity-token", attest.getString("token"))
        assertEquals(listOf(EXPECTED_HASH), fake.hashes.toList())
    }

    @Test
    fun anUnsupportedDeviceSendsUnavailableAndAsksForNoChallenge() = bounded {
        route()
        fake.prepareFailure = AttestUnavailable("unsupported")
        assertEquals("gs_1", guestSessionFor(client(), AttestConfig("report", "1")))
        assertEquals(listOf("/v1/guest/session"), server.requests.map { it.path })
        val attest = JSONObject(server.requests.single().body).getJSONObject("attest")
        assertEquals(setOf("platform", "unavailable"), keysOf(attest))
        assertEquals("android", attest.getString("platform"))
        assertEquals("unsupported", attest.getString("unavailable"))
    }

    @Test
    fun noCloudProjectSendsUnavailableAndTouchesNothing() = bounded {
        route()
        guestSessionFor(client(), AttestConfig("enforce", null))
        val attest = JSONObject(server.requests.single().body).getJSONObject("attest")
        assertEquals("no_cloud_project", attest.getString("unavailable"))
        assertEquals(0, fake.calls)
    }

    @Test
    fun aChallengeEndpointThatNeverAnswersEndsAsATimeoutWithinTheCap() = bounded {
        route(challenge = null)
        val started = System.nanoTime()
        // The api itself would wait 15 s; the attestation cap (here 400 ms) ends it first and the request is abandoned.
        val session = guestSessionFor(client(), AttestConfig("report", "1"), GuestAttestation(fake, scope, timeoutMs = 400))
        val ms = (System.nanoTime() - started) / 1_000_000
        assertEquals("gs_1", session)
        assertTrue("took $ms ms", ms < 4_000)
        val attest = JSONObject(server.requests.last().body).getJSONObject("attest")
        assertEquals("timeout", attest.getString("unavailable"))
        assertTrue("the token must not be requested without a challenge", fake.hashes.isEmpty())
    }

    // ---- refusals ----

    @Test
    fun attestationRequiredAndFailedAreRefusalsAndNeverFatalAttemptErrors() = bounded {
        for ((code, reason) in listOf("attestation_required" to "no_attestation", "attestation_failed" to "challenge_expired")) {
            route(guest = 403 to """{"error":"$code","reason":"$reason","message":"no"}""")
            val e = failureOf { guestSessionFor(client(), AttestConfig("enforce", "1")) }
            assertTrue("got $e", e is ApiError)
            val api = e as ApiError
            assertEquals(403, api.status)
            assertEquals(code, api.code)
            assertTrue("$code must end the guest offers (noFill)", api.isAttestationRefusal)
            assertFalse("$code is not an attempt-level fatal error", api.isFatal)
        }
    }

    @Test
    fun otherErrorsAreNotAttestationRefusals() = bounded {
        for ((status, code) in listOf(403 to "guests_not_allowed", 403 to "not_eligible", 400 to "attest_invalid", 400 to "bad_request", 429 to "quota_full")) {
            route(guest = status to """{"error":"$code"}""")
            val e = failureOf { client().guestSession(INSTALL, null) } as ApiError
            assertEquals(code, e.code)
            assertFalse("$status $code", e.isAttestationRefusal)
        }
        // The same error code from anywhere but a 403 is not the refusal either.
        assertFalse(ApiError(500, "attestation_failed", "").isAttestationRefusal)
    }

    @Test
    fun afterARefusalTheNextGuestSessionAttestsAgainWithAFreshChallenge() = bounded {
        route(guest = 403 to """{"error":"attestation_failed","reason":"device_not_trusted"}""")
        val api = client()
        assertNotNull(failureOf { guestSessionFor(api, AttestConfig("enforce", "1")) })
        route() // the next time FOUNTIS vouches for the device
        assertEquals("gs_1", guestSessionFor(api, AttestConfig("enforce", "1")))
        // Two full rounds, challenge then session, and Play Integrity prepared only once.
        assertEquals(
            listOf("/v1/attest/challenge", "/v1/guest/session", "/v1/attest/challenge", "/v1/guest/session"),
            server.requests.map { it.path },
        )
        assertEquals(listOf(1L), fake.prepared.toList())
        assertEquals(2, fake.hashes.size)
    }

    // ---- the cooldown after a refusal ----

    @Test
    fun afterARefusalNothingIsSentForTenMinutes() = bounded {
        route(guest = 403 to """{"error":"attestation_failed","reason":"device_not_trusted"}""")
        var now = 0L
        val opener = GuestSessionOpener({ attestation }, RefusalCooldown(now = { now }))
        val api = client()
        val config = AttestConfig("enforce", "1")

        val first = failureOf { opener.open(api, config, INSTALL) } as ApiError
        assertTrue(first.isAttestationRefusal)
        val sent = server.requests.size
        val tokens = fake.hashes.size
        assertEquals("the first try attests and asks for the session", 2, sent)

        now = 9 * 60_000L
        val second = failureOf { opener.open(api, config, INSTALL) } as ApiError
        assertTrue("still a refusal, so the SDK ends as noFill", second.isAttestationRefusal)
        assertEquals("attestation_failed", second.code)
        assertEquals("nothing was sent within the 10 minutes", sent, server.requests.size)
        assertEquals("no Play Integrity token was spent", tokens, fake.hashes.size)

        now = 10 * 60_000L + 1
        route() // the next time FOUNTIS vouches for the device
        assertEquals("gs_1", opener.open(api, config, INSTALL))
        assertEquals("after the window it attests and asks again", sent + 2, server.requests.size)
        assertEquals(tokens + 1, fake.hashes.size)
    }

    @Test
    fun anAppWithAttestationOffIsNotHeldBackByARecentRefusal() = bounded {
        route(guest = 403 to """{"error":"attestation_required"}""")
        val opener = GuestSessionOpener({ attestation }, RefusalCooldown(now = { 0L }))
        val api = client()
        assertTrue((failureOf { opener.open(api, AttestConfig("enforce", "1"), INSTALL) } as ApiError).isAttestationRefusal)
        route() // attestation is off for the app now
        assertEquals("gs_1", opener.open(api, AttestConfig.OFF, INSTALL))
    }

    @Test
    fun aRefusalOtherThanAttestationDoesNotStartTheCooldown() = bounded {
        route(guest = 403 to """{"error":"guests_not_allowed"}""")
        val opener = GuestSessionOpener({ attestation }, RefusalCooldown(now = { 0L }))
        val api = client()
        val config = AttestConfig("enforce", "1")
        assertEquals("guests_not_allowed", (failureOf { opener.open(api, config, INSTALL) } as ApiError).code)
        val sent = server.requests.size
        failureOf { opener.open(api, config, INSTALL) }
        assertTrue("the second try must go out", server.requests.size > sent)
    }

    companion object {
        const val CHALLENGE = "dGVzdC1jaGFsbGVuZ2U"
        const val INSTALL = "install_ABCDEFGHIJKLMNOPQ"
        const val EXPECTED_HASH = "de0b8990c5fd7bcd477a2575351be91c273d6f9b63b6d4bb5d7f60e04a204430"
    }
}
