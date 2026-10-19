package org.fountis.connect

import android.content.Context
import com.google.android.gms.tasks.Task
import com.google.android.play.core.integrity.IntegrityManagerFactory
import com.google.android.play.core.integrity.StandardIntegrityException
import com.google.android.play.core.integrity.StandardIntegrityManager
import com.google.android.play.core.integrity.StandardIntegrityManager.PrepareIntegrityTokenRequest
import com.google.android.play.core.integrity.StandardIntegrityManager.StandardIntegrityTokenProvider
import com.google.android.play.core.integrity.StandardIntegrityManager.StandardIntegrityTokenRequest
import java.util.concurrent.Executor
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.suspendCancellableCoroutine

/**
 * Play Integrity, Standard API. The only file that touches Google's classes. An app installed outside Google Play, or a
 * device without Play Store or Play services, simply gets an [AttestUnavailable] here; nothing else changes for it.
 *
 * Play Integrity is not started until the first [prepare], which only happens for a guest of an app whose attestation
 * mode is `report` or `enforce`.
 */
internal class PlayIntegrityAttestor(context: Context) : Attestor {
    private val appContext: Context = context.applicationContext

    private val manager: StandardIntegrityManager by lazy { IntegrityManagerFactory.createStandard(appContext) }

    @Volatile private var provider: StandardIntegrityTokenProvider? = null

    override suspend fun prepare(cloudProjectNumber: Long) {
        try {
            val prepareRequest = PrepareIntegrityTokenRequest.builder().setCloudProjectNumber(cloudProjectNumber).build()
            provider = manager.prepareIntegrityToken(prepareRequest).awaitTask()
        } catch (e: CancellationException) {
            throw e
        } catch (t: Throwable) {
            throw unavailableFor(t)
        }
    }

    override suspend fun request(requestHash: String): String {
        val p = provider ?: throw AttestUnavailable("error")
        return try {
            val tokenRequest = StandardIntegrityTokenRequest.builder().setRequestHash(requestHash).build()
            p.request(tokenRequest).awaitTask().token()
        } catch (e: CancellationException) {
            throw e
        } catch (t: Throwable) {
            throw unavailableFor(t)
        }
    }

    private fun unavailableFor(t: Throwable): AttestUnavailable {
        if (t is AttestUnavailable) return t
        // The Play Integrity classes missing at run time (for example stripped by a shrinker): this device cannot attest.
        if (t is LinkageError) return AttestUnavailable("unsupported", t)
        val errorCode = (t as? StandardIntegrityException)?.errorCode
        return AttestUnavailable(attestCodeForPlayError(errorCode), t)
    }
}

/** Callbacks run right where Google delivers them: they only resume the coroutine, so the main thread is not needed. */
private val DIRECT_EXECUTOR = Executor { it.run() }

private suspend fun <T> Task<T>.awaitTask(): T = suspendCancellableCoroutine { cont ->
    addOnSuccessListener(DIRECT_EXECUTOR) { cont.resume(it) }
    addOnFailureListener(DIRECT_EXECUTOR) { cont.resumeWithException(it) }
    addOnCanceledListener(DIRECT_EXECUTOR) { cont.resumeWithException(AttestUnavailable("error")) }
}
