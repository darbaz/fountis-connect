package org.fountis.connect

import java.security.MessageDigest
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject

// Device attestation for guests (Play Integrity, Standard API). Only guest sessions are attested: a signed-in partner
// user is vouched for by the partner's signed token. Everything here is silent, nothing about it is shown to the person.
// This file has no Play Integrity import on purpose: the plain-JVM unit tests run it with a fake [Attestor].

/** The most the whole attestation may take (challenge, waiting for Play Integrity, token), as on iOS. */
internal const val ATTEST_TIMEOUT_MS: Long = 10_000L

/** `app.attest` from `GET /surveys`: whether to attest, and the Google Cloud project NUMBER the partner linked in Play Console. */
internal class AttestConfig(val mode: String, val androidCloudProject: String?) {
    /** Only `report` and `enforce` attest. `off`, a missing `attest` object and any mode this SDK does not know do not. */
    val isOn: Boolean get() = mode == "report" || mode == "enforce"

    /** The project number, or null when none is configured (or it is not a positive number). */
    val cloudProjectNumber: Long? get() = androidCloudProject?.trim()?.toLongOrNull()?.takeIf { it > 0L }

    companion object {
        val OFF = AttestConfig("off", null)
    }
}

/** The device could not attest. [code] is the wire code the server expects: `unsupported`, `error` or `no_cloud_project`. */
internal class AttestUnavailable(val code: String, cause: Throwable? = null) : Exception("attestation unavailable: $code", cause)

/** What Play Integrity offers the SDK, so the unit tests can fake it. */
internal interface Attestor {
    /** Gets Play Integrity ready for [cloudProjectNumber]. The slow part (a few seconds); the SDK calls it once per process. Throws [AttestUnavailable]. */
    suspend fun prepare(cloudProjectNumber: Long)

    /** An integrity token bound to [requestHash]. Needs [prepare] to have finished. Throws [AttestUnavailable]. */
    suspend fun request(requestHash: String): String
}

/**
 * The `requestHash` Play Integrity binds into the token: lowercase hex SHA-256 of `challenge + "|" + installId`
 * (UTF-8). The server recomputes it from the challenge it issued and the install id of the guest session request.
 */
internal fun attestRequestHash(challenge: String, installId: String): String {
    val digest = MessageDigest.getInstance("SHA-256").digest("$challenge|$installId".toByteArray(Charsets.UTF_8))
    return digest.joinToString("") { "%02x".format(it.toInt() and 0xff) }
}

/**
 * The wire code for a Play Integrity Standard API error (`StandardIntegrityErrorCode`), or `error` when the code is
 * unknown or there is none. `unsupported`: this device or Play setup cannot attest (no Play Store or Play services, too
 * old, API not available, app not installed from Play). A cloud project Google rejects counts as `no_cloud_project`: it
 * is the same fix (the project number in the FOUNTIS console). Everything else (network, quota, Google busy) is `error`.
 */
internal fun attestCodeForPlayError(errorCode: Int?): String {
    if (errorCode == null) return "error"
    if (errorCode in PLAY_UNSUPPORTED) return "unsupported"
    if (errorCode == -16) return "no_cloud_project" // CLOUD_PROJECT_NUMBER_IS_INVALID
    return "error"
}

/**
 * API_NOT_AVAILABLE -1, PLAY_STORE_NOT_FOUND -2, PLAY_STORE_ACCOUNT_NOT_FOUND -4, APP_NOT_INSTALLED -5,
 * PLAY_SERVICES_NOT_FOUND -6, CANNOT_BIND_TO_SERVICE -9, PLAY_STORE_VERSION_OUTDATED -14, PLAY_SERVICES_VERSION_OUTDATED -15.
 */
private val PLAY_UNSUPPORTED: Set<Int> = setOf(-1, -2, -4, -5, -6, -9, -14, -15)

/**
 * Builds the `attest` object of `POST /guest/session`.
 *
 * - Attestation off: [attest] returns null and nothing is touched (no request, no Play Integrity).
 * - Otherwise it always returns an object: the token, or `unavailable` with a code when the device could not attest
 *   (the server decides what an unavailable attestation means: `report` grants the session, `enforce` refuses it).
 *   It never throws, except to pass on the caller's own cancellation.
 *
 * Play Integrity is prepared once per process (and project): [warmUp] starts it early in the background, [attest]
 * starts it if nobody did and waits for it. A failed preparation is forgotten, so the next guest session tries again.
 * The preparation is not tied to the caller, so an attestation that timed out leaves it running for the next one.
 *
 * [scope] must have a `SupervisorJob`. The work runs on `Dispatchers.Default`, never on the main thread.
 */
internal class GuestAttestation(
    private val attestor: Attestor,
    private val scope: CoroutineScope,
    private val timeoutMs: Long = ATTEST_TIMEOUT_MS,
) {
    /** [ready] ends with null when Play Integrity is prepared, or with the unavailable code when it could not be. */
    private class Warm(val project: Long, val ready: Deferred<String?>)

    private var warm: Warm? = null

    @Synchronized
    private fun warmFor(project: Long): Warm {
        val have = warm
        if (have != null && have.project == project) return have
        val w = Warm(project, scope.async(Dispatchers.Default) { prepared(project) })
        warm = w
        return w
    }

    @Synchronized
    private fun forget(w: Warm) {
        if (warm === w) warm = null
    }

    private suspend fun prepared(project: Long): String? = try {
        attestor.prepare(project)
        null
    } catch (e: CancellationException) {
        throw e
    } catch (e: AttestUnavailable) {
        e.code
    } catch (t: Throwable) {
        logd("attest: Play Integrity could not be prepared: $t")
        "error"
    }

    /** Starts preparing Play Integrity in the background, once. Does nothing when attestation is off or no project is set. */
    fun warmUp(config: AttestConfig) {
        if (!config.isOn) return
        val project = config.cloudProjectNumber ?: return
        warmFor(project)
    }

    /**
     * The `attest` object for the guest session of [installId], or null when [config] has attestation off.
     * [challenge] fetches a fresh single-use challenge from FOUNTIS; it is only called once Play Integrity is ready.
     */
    suspend fun attest(config: AttestConfig, installId: String, challenge: suspend () -> String): JSONObject? {
        if (!config.isOn) return null
        val result = withTimeoutOrNull(timeoutMs) {
            withContext(Dispatchers.Default) { attestInTime(config, installId, challenge) }
        }
        if (result == null) logd("attest: no result within ${timeoutMs / 1000.0} s")
        return result ?: unavailable("timeout")
    }

    private suspend fun attestInTime(config: AttestConfig, installId: String, challenge: suspend () -> String): JSONObject {
        val project = config.cloudProjectNumber ?: return unavailable("no_cloud_project")

        val w = warmFor(project)
        val notReady = w.ready.await()
        if (notReady != null) {
            forget(w)
            return unavailable(notReady)
        }

        val c = try {
            challenge()
        } catch (e: CancellationException) {
            throw e
        } catch (t: Throwable) {
            logd("attest: no challenge: $t")
            return unavailable("error")
        }

        val token = try {
            attestor.request(attestRequestHash(c, installId))
        } catch (e: CancellationException) {
            throw e
        } catch (t: Throwable) {
            // The token provider may have expired or been invalidated: prepare it again for the next guest session.
            forget(w)
            logd("attest: no token: $t")
            return unavailable(if (t is AttestUnavailable) t.code else "error")
        }

        return JSONObject().put("platform", "android").put("token", token).put("challenge", c)
    }

    private fun unavailable(code: String): JSONObject = JSONObject().put("platform", "android").put("unavailable", code)
}

/** After FOUNTIS refuses a guest session for lack of a valid attestation, the SDK leaves it alone for this long. */
internal const val ATTEST_REFUSAL_COOLDOWN_MS: Long = 10 * 60_000L

/**
 * Remembers, in memory only, that FOUNTIS refused this install a guest session (403 `attestation_required` /
 * `attestation_failed`). Every attestation spends one Play Integrity token from the app's daily quota, so a device that
 * will be refused again must not try on every `show()`. The clock is monotonic.
 */
internal class RefusalCooldown(
    private val now: () -> Long = { System.nanoTime() / 1_000_000L },
    private val windowMs: Long = ATTEST_REFUSAL_COOLDOWN_MS,
) {
    private var until: Long? = null
    private var code = "attestation_failed"

    @Synchronized
    fun record(code: String) {
        this.code = code
        until = now() + windowMs
    }

    /** The code of the refusal while the window is open, otherwise null. */
    @Synchronized
    fun active(): String? {
        val u = until ?: return null
        return if (now() < u) code else null
    }
}

/**
 * Gets a guest session from FOUNTIS: attests first when [cfg] asks for it, and keeps to the [cooldown] after a refusal.
 * [attestation] is only called for an app whose mode is `report` or `enforce`, so Play Integrity stays untouched otherwise.
 */
internal class GuestSessionOpener(
    private val attestation: () -> GuestAttestation?,
    private val cooldown: RefusalCooldown = RefusalCooldown(),
) {
    /**
     * The guest session token. Throws the same [ApiError] FOUNTIS refused with (see [ApiError.isAttestationRefusal]),
     * and, within the cooldown after such a refusal, a 403 with the same code without sending anything at all.
     */
    suspend fun open(api: ApiClient, cfg: AttestConfig, installId: String): String {
        var attest: JSONObject? = null
        if (cfg.isOn) {
            val recent = cooldown.active()
            if (recent != null) throw ApiError(403, recent, "refused a moment ago")
            attest = attestation()?.attest(cfg, installId) { api.attestChallenge() }
        }
        try {
            return api.guestSession(installId, attest)
        } catch (e: ApiError) {
            if (e.isAttestationRefusal) cooldown.record(e.code)
            throw e
        }
    }
}
