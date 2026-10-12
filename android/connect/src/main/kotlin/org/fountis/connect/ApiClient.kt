package org.fountis.connect

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import org.json.JSONObject

internal class ApiError(val status: Int, val code: String, override val message: String) : Exception(message) {
    /** Errors that end the attempt for good (the engine shows the matching screen). */
    val isFatal: Boolean get() = code in FATAL

    companion object {
        val FATAL = setOf("invalid_token", "not_eligible", "already_taken", "closed", "quota_full")
    }
}

/**
 * One request in flight, reachable from the thread that gave up waiting for it: [abandon] closes its connection so the
 * thread blocked on the socket is freed, and the read loop checks it so a body that is still trickling in stops too.
 */
internal class Exchange {
    @Volatile private var conn: HttpURLConnection? = null
    @Volatile private var abandoned = false

    /** Remembers the connection. Throws if the caller has already given up, so the request never starts. */
    fun attach(c: HttpURLConnection) {
        conn = c
        checkNotAbandoned()
    }

    fun checkNotAbandoned() {
        if (abandoned) throw IOException("the request was abandoned")
    }

    /** Called on another thread once the caller stopped waiting. Best effort: the caller is already released. */
    fun abandon() {
        abandoned = true
        conn?.disconnect()
    }
}

/**
 * Thin client for the connect-api (HttpURLConnection, no cookies, no cache). Tokens are only ever sent in headers or bodies.
 *
 * Every request has an overall deadline ([deadlineMs], 15 s): connection, request and the whole response body. The
 * per-step limits on the connection alone cannot give that, because a server that sends a byte now and then keeps
 * every single read within its limit. When the deadline passes the call fails with a [RequestTimeoutException], an
 * [IOException] like the read timeout it replaces, so it ends as noFill the same way.
 */
internal class ApiClient(base: String, val key: String, private val deadlineMs: Long = REQUEST_DEADLINE_MS) {
    private val base = base.trimEnd('/')

    /** Where the blocking requests run. A SupervisorJob keeps a failed request in its Deferred. It owns no thread of its own. */
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private fun Exchange.request(method: String, path: String, query: Map<String, String> = emptyMap(), body: JSONObject? = null, attemptToken: String? = null): String {
        var url = "$base/$path"
        if (query.isNotEmpty()) url += "?" + query.entries.joinToString("&") { URLEncoder.encode(it.key, "UTF-8") + "=" + URLEncoder.encode(it.value, "UTF-8") }
        val conn = URL(url).openConnection() as HttpURLConnection
        try {
            attach(conn)
            conn.requestMethod = method
            // Second line of defence only: the deadline ends a request first (these are per step, the deadline is the whole).
            conn.connectTimeout = 15_000
            conn.readTimeout = 20_000
            conn.useCaches = false
            conn.instanceFollowRedirects = false
            conn.setRequestProperty("X-Fountis-Key", key)
            conn.setRequestProperty("Accept", "application/json")
            if (attemptToken != null) conn.setRequestProperty("Authorization", "Attempt $attemptToken")
            if (body != null) {
                conn.doOutput = true
                conn.setRequestProperty("Content-Type", "application/json")
                conn.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
            }
            val status = conn.responseCode
            val stream = if (status in 200..299) conn.inputStream else conn.errorStream
            val text = readBody(stream)
            if (status in 200..299) return text
            var code = "http_$status"
            var message = ""
            try {
                val o = JSONObject(text)
                code = o.optString("error", code)
                message = o.optString("message", "")
            } catch (_: Exception) {
            }
            throw ApiError(status, code, message)
        } finally {
            conn.disconnect()
        }
    }

    /** Reads the body in pieces, so an abandoned request stops at the next piece instead of waiting for the whole body. */
    private fun Exchange.readBody(stream: InputStream?): String {
        if (stream == null) return ""
        return stream.use { s ->
            val out = ByteArrayOutputStream()
            val buf = ByteArray(8192)
            var n = s.read(buf)
            while (n >= 0) {
                checkNotAbandoned()
                out.write(buf, 0, n)
                n = s.read(buf)
            }
            out.toString("UTF-8")
        }
    }

    private suspend fun io(work: Exchange.() -> String): String {
        val exchange = Exchange()
        return callWithinDeadline(scope, deadlineMs, abandon = exchange::abandon) { exchange.work() }
    }

    private fun obj(text: String): JSONObject =
        try {
            JSONObject(text)
        } catch (e: Exception) {
            throw ApiError(0, "bad_response", "unexpected response")
        }

    suspend fun surveys(lang: String): SurveysResponse =
        parseSurveys(io { request("GET", "surveys", query = mapOf("lang" to lang)) })

    suspend fun createAttempt(offerId: String, token: String, lang: String): JSONObject =
        obj(io { request("POST", "attempts", body = JSONObject().put("offer_id", offerId).put("token", token).put("lang", lang)) })

    /** Guests: the install id in, a short-lived guest session token out. 403 `guests_not_allowed` when the app has guests off. */
    suspend fun guestSession(installId: String): String {
        val o = obj(io { request("POST", "guest/session", body = JSONObject().put("install_id", installId)) })
        return o.optString("guest_session", "").ifEmpty { throw ApiError(0, "bad_response", "no session") }
    }

    suspend fun createGuestAttempt(offerId: String, guestSession: String, lang: String): JSONObject =
        obj(io { request("POST", "attempts", body = JSONObject().put("offer_id", offerId).put("guest_session", guestSession).put("lang", lang)) })

    suspend fun putAnswer(code: String, value: Any?, attemptToken: String): JSONObject =
        obj(io { request("PUT", "attempt/answers", body = JSONObject().put("code", code).put("value", value ?: JSONObject.NULL), attemptToken = attemptToken) })

    suspend fun consent(attemptToken: String) {
        io { request("POST", "attempt/consent", body = JSONObject(), attemptToken = attemptToken) }
    }

    suspend fun complete(attemptToken: String): JSONObject =
        obj(io { request("POST", "attempt/complete", body = JSONObject(), attemptToken = attemptToken) })

    suspend fun event(offerId: String, type: String) {
        try {
            io { request("POST", "events", body = JSONObject().put("offer_id", offerId).put("type", type)) }
        } catch (_: IOException) {
        } catch (_: ApiError) {
        } catch (_: RuntimeException) {
        }
    }
}
