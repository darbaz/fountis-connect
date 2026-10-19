package org.fountis.connect

import java.io.IOException
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
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
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Guest attestation with a fake Play Integrity: what is sent for each mode, and every way it can be unavailable. */
class GuestAttestationTest {
    /** A stand-in for Play Integrity. Records what the SDK asks of it. */
    private class FakeAttestor : Attestor {
        val prepared = CopyOnWriteArrayList<Long>()
        val hashes = CopyOnWriteArrayList<String>()

        @Volatile var token = "integrity-token"
        @Volatile var prepareFailure: Throwable? = null
        @Volatile var requestFailure: Throwable? = null
        @Volatile var requestHangs = false
        @Volatile var prepareDelayMs = 0L

        val calls: Int get() = prepared.size + hashes.size

        override suspend fun prepare(cloudProjectNumber: Long) {
            prepared.add(cloudProjectNumber)
            if (prepareDelayMs > 0) delay(prepareDelayMs)
            prepareFailure?.let { throw it }
        }

        override suspend fun request(requestHash: String): String {
            hashes.add(requestHash)
            requestFailure?.let { throw it }
            if (requestHangs) delay(60_000)
            return token
        }
    }

    /** Stands in for `POST /attest/challenge`. */
    private class Challenges {
        val calls = AtomicInteger()

        @Volatile var failure: Throwable? = null

        suspend fun next(): String {
            calls.incrementAndGet()
            failure?.let { throw it }
            return CHALLENGE
        }
    }

    private val scope = CoroutineScope(SupervisorJob())
    private val fake = FakeAttestor()
    private val challenges = Challenges()

    @After
    fun tearDown() {
        scope.cancel()
    }

    private fun attestation(timeoutMs: Long = 5_000) = GuestAttestation(fake, scope, timeoutMs)

    private suspend fun GuestAttestation.go(config: AttestConfig): JSONObject? = attest(config, INSTALL) { challenges.next() }

    /** Runs [body] on the test thread, failing it (not hanging CI) after 5 s. */
    private fun bounded(body: suspend CoroutineScope.() -> Unit) {
        runBlocking { withTimeout(5_000) { body(this) } }
    }

    private fun keysOf(o: JSONObject): Set<String> = o.keys().asSequence().toSet()

    private fun assertUnavailable(code: String, o: JSONObject?) {
        assertNotNull("expected an attest object", o)
        assertEquals("android", o!!.getString("platform"))
        assertEquals(code, o.getString("unavailable"))
        assertEquals("an unavailable attest carries nothing else: $o", setOf("platform", "unavailable"), keysOf(o))
    }

    // ---- mode off ----

    @Test
    fun modeOffNeverTouchesPlayIntegrityOrTheChallengeEndpoint() = bounded {
        val a = attestation()
        for (config in listOf(AttestConfig.OFF, AttestConfig("off", "123456789012"), AttestConfig("surprise", "123456789012"), AttestConfig("", "123456789012"))) {
            a.warmUp(config)
            assertNull("mode '${config.mode}' must send no attest", a.go(config))
        }
        delay(150) // a background warm-up would have started by now
        assertEquals("Play Integrity was touched", 0, fake.calls)
        assertEquals("the challenge endpoint was called", 0, challenges.calls.get())
    }

    @Test
    fun onlyReportAndEnforceAttest() {
        assertTrue(AttestConfig("report", null).isOn)
        assertTrue(AttestConfig("enforce", null).isOn)
        assertTrue(!AttestConfig("off", null).isOn)
        assertTrue(!AttestConfig("ENFORCE", null).isOn)
        assertTrue(!AttestConfig.OFF.isOn)
    }

    // ---- report / enforce ----

    @Test
    fun reportSendsTheTokenTheChallengeAndTheRightRequestHash() = bounded {
        val o = attestation().go(AttestConfig("report", "123456789012"))
        assertNotNull(o)
        assertEquals("android", o!!.getString("platform"))
        assertEquals("integrity-token", o.getString("token"))
        assertEquals(CHALLENGE, o.getString("challenge"))
        assertEquals(setOf("platform", "token", "challenge"), keysOf(o))
        assertEquals(listOf(123456789012L), fake.prepared.toList())
        assertEquals(listOf(EXPECTED_HASH), fake.hashes.toList())
        assertEquals(1, challenges.calls.get())
    }

    @Test
    fun enforceAttestsTheSameWay() = bounded {
        val o = attestation().go(AttestConfig("enforce", "42"))
        assertEquals("integrity-token", o!!.getString("token"))
        assertEquals(listOf(EXPECTED_HASH), fake.hashes.toList())
    }

    @Test
    fun theRequestHashIsLowercaseHexSha256OfChallengeBarInstallId() {
        assertEquals(EXPECTED_HASH, attestRequestHash(CHALLENGE, INSTALL))
        assertEquals("0def6826e591afbb7b4431daaa6f2a78c1e5af533cb94b6db1635efbf255cb16", attestRequestHash("abc", "def"))
        assertTrue(Regex("^[0-9a-f]{64}$").matches(attestRequestHash("x", "y")))
        // The order and the bar matter: the server hashes exactly challenge + "|" + install_id.
        assertTrue(attestRequestHash("a", "b") != attestRequestHash("b", "a"))
    }

    // ---- unavailable ----

    @Test
    fun noCloudProjectIsReportedAndNothingIsTouched() = bounded {
        for (project in listOf(null, "", "   ", "abc", "0", "-5", "12.5")) {
            assertUnavailable("no_cloud_project", attestation().go(AttestConfig("report", project)))
        }
        assertEquals(0, fake.calls)
        assertEquals(0, challenges.calls.get())
    }

    @Test
    fun theProjectNumberMayHaveSpaces() = bounded {
        attestation().go(AttestConfig("report", " 987654321 "))
        assertEquals(listOf(987654321L), fake.prepared.toList())
    }

    @Test
    fun anUnsupportedDeviceIsReportedWithoutAskingForAChallenge() = bounded {
        fake.prepareFailure = AttestUnavailable("unsupported")
        assertUnavailable("unsupported", attestation().go(AttestConfig("report", "1")))
        assertEquals(0, challenges.calls.get())
        assertTrue(fake.hashes.isEmpty())
    }

    @Test
    fun aPreparationFailureOfAnyOtherKindIsAnError() = bounded {
        fake.prepareFailure = IllegalStateException("boom")
        assertUnavailable("error", attestation().go(AttestConfig("enforce", "1")))
    }

    @Test
    fun theCodeOfAnAttestorFailureIsPassedOn() = bounded {
        fake.prepareFailure = AttestUnavailable("no_cloud_project")
        assertUnavailable("no_cloud_project", attestation().go(AttestConfig("report", "1")))
    }

    @Test
    fun aTokenRequestFailureIsReportedWithItsCode() = bounded {
        fake.requestFailure = AttestUnavailable("unsupported")
        assertUnavailable("unsupported", attestation().go(AttestConfig("report", "1")))
        fake.requestFailure = RuntimeException("boom")
        assertUnavailable("error", attestation().go(AttestConfig("report", "1")))
    }

    @Test
    fun aFailingChallengeCallIsAnError() = bounded {
        challenges.failure = IOException("offline")
        assertUnavailable("error", attestation().go(AttestConfig("report", "1")))
        assertTrue(fake.hashes.isEmpty())
    }

    // ---- the 10 s cap ----

    @Test
    fun aTokenRequestThatNeverAnswersEndsAsATimeout() = bounded {
        fake.requestHangs = true
        val started = System.nanoTime()
        val o = attestation(timeoutMs = 300).go(AttestConfig("report", "1"))
        val ms = (System.nanoTime() - started) / 1_000_000
        assertUnavailable("timeout", o)
        assertTrue("ended after $ms ms, before the 300 ms cap", ms >= 250)
        assertTrue("ended after $ms ms, long after the cap", ms < 3_000)
    }

    @Test
    fun aSlowPreparationTimesOutButKeepsRunningForTheNextGuestSession() = bounded {
        fake.prepareDelayMs = 600
        val a = attestation(timeoutMs = 200)
        assertUnavailable("timeout", a.go(AttestConfig("report", "1")))
        delay(900) // the preparation finished in the background
        val o = a.go(AttestConfig("report", "1"))
        assertEquals("integrity-token", o!!.getString("token"))
        assertEquals("prepared once, not again after the timeout", 1, fake.prepared.size)
    }

    @Test
    fun cancellingTheCallerIsNotSwallowed() = bounded {
        fake.requestHangs = true
        val a = attestation(timeoutMs = 60_000)
        val outcome = CompletableDeferred<Throwable?>()
        val caller = launch(Dispatchers.Default) {
            try {
                a.go(AttestConfig("report", "1"))
                outcome.complete(null)
            } catch (t: Throwable) {
                outcome.complete(t)
            }
        }
        while (fake.hashes.isEmpty()) delay(10) // the token request is really in flight
        caller.cancel()
        val e = withTimeout(1_000) { outcome.await() }
        assertTrue("cancellation must reach the caller, got $e", e is CancellationException)
    }

    // ---- once per process ----

    @Test
    fun playIntegrityIsPreparedOncePerProcessForAnyNumberOfGuestSessions() = bounded {
        val a = attestation()
        val config = AttestConfig("report", "1")
        a.warmUp(config)
        a.warmUp(config)
        a.go(config)
        a.go(config)
        a.go(config)
        assertEquals(listOf(1L), fake.prepared.toList())
        assertEquals(3, fake.hashes.size)
    }

    @Test
    fun aChangedProjectNumberIsPreparedAgain() = bounded {
        val a = attestation()
        a.go(AttestConfig("report", "1"))
        a.go(AttestConfig("report", "2"))
        assertEquals(listOf(1L, 2L), fake.prepared.toList())
    }

    @Test
    fun aFailedPreparationIsTriedAgainOnTheNextGuestSession() = bounded {
        val a = attestation()
        val config = AttestConfig("report", "1")
        fake.prepareFailure = AttestUnavailable("error")
        assertUnavailable("error", a.go(config))
        fake.prepareFailure = null
        assertEquals("integrity-token", a.go(config)!!.getString("token"))
        assertEquals(2, fake.prepared.size)
    }

    @Test
    fun aFailedTokenRequestPreparesAgainNextTime() = bounded {
        val a = attestation()
        val config = AttestConfig("report", "1")
        fake.requestFailure = AttestUnavailable("error")
        assertUnavailable("error", a.go(config))
        fake.requestFailure = null
        assertEquals("integrity-token", a.go(config)!!.getString("token"))
        assertEquals(2, fake.prepared.size)
    }

    // ---- Play Integrity error codes ----

    @Test
    fun playErrorCodesMapToTheWireCodes() {
        // StandardIntegrityErrorCode: API_NOT_AVAILABLE, PLAY_STORE_NOT_FOUND, PLAY_STORE_ACCOUNT_NOT_FOUND, APP_NOT_INSTALLED,
        // PLAY_SERVICES_NOT_FOUND, CANNOT_BIND_TO_SERVICE, PLAY_STORE_VERSION_OUTDATED, PLAY_SERVICES_VERSION_OUTDATED
        for (code in listOf(-1, -2, -4, -5, -6, -9, -14, -15)) assertEquals("code $code", "unsupported", attestCodeForPlayError(code))
        assertEquals("no_cloud_project", attestCodeForPlayError(-16))
        // NETWORK_ERROR, APP_UID_MISMATCH, TOO_MANY_REQUESTS, GOOGLE_SERVER_UNAVAILABLE, REQUEST_HASH_TOO_LONG, CLIENT_TRANSIENT_ERROR,
        // INTEGRITY_TOKEN_PROVIDER_INVALID, INTERNAL_ERROR, and anything unknown
        for (code in listOf(-3, -7, -8, -12, -17, -18, -19, -100, 0, 7)) assertEquals("code $code", "error", attestCodeForPlayError(code))
        assertEquals("error", attestCodeForPlayError(null))
    }

    // ---- GET /surveys: app.attest ----

    private fun parse(app: String): SurveysResponse = parseSurveys("""{"app":$app,"surveys":[]}""")

    @Test
    fun theAttestSettingIsReadFromTheApp() {
        val r = parse("""{"name":"Demo","guests":true,"attest":{"mode":"enforce","android_cloud_project":"123456789012"}}""")
        assertEquals("enforce", r.attest.mode)
        assertTrue(r.attest.isOn)
        assertEquals(123456789012L, r.attest.cloudProjectNumber)
    }

    @Test
    fun noAttestSettingMeansOff() {
        assertTrue(!parse("""{"name":"Demo","guests":true}""").attest.isOn)
        assertTrue(!parseSurveys("""{"surveys":[]}""").attest.isOn)
        assertTrue(!parse("""{"attest":null}""").attest.isOn)
        assertTrue(!parse("""{"attest":{}}""").attest.isOn)
        assertTrue(!parse("""{"attest":{"mode":null}}""").attest.isOn)
        assertTrue(!parse("""{"attest":{"mode":"something-new"}}""").attest.isOn)
    }

    @Test
    fun aMissingOrNullCloudProjectIsNoProject() {
        assertNull(parse("""{"attest":{"mode":"report","android_cloud_project":null}}""").attest.cloudProjectNumber)
        assertNull(parse("""{"attest":{"mode":"report"}}""").attest.cloudProjectNumber)
        assertNull(parse("""{"attest":{"mode":"report","android_cloud_project":"not a number"}}""").attest.cloudProjectNumber)
    }

    @Test
    fun aBareNumberCloudProjectIsAccepted() {
        assertEquals(123456789012L, parse("""{"attest":{"mode":"report","android_cloud_project":123456789012}}""").attest.cloudProjectNumber)
    }

    companion object {
        const val CHALLENGE = "dGVzdC1jaGFsbGVuZ2U"
        const val INSTALL = "install_ABCDEFGHIJKLMNOPQ"

        /** sha256 of "dGVzdC1jaGFsbGVuZ2U|install_ABCDEFGHIJKLMNOPQ", computed outside this code base. */
        const val EXPECTED_HASH = "de0b8990c5fd7bcd477a2575351be91c273d6f9b63b6d4bb5d7f60e04a204430"
    }
}
