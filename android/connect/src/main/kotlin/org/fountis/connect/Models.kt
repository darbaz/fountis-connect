package org.fountis.connect

import org.json.JSONArray
import org.json.JSONObject

/** What `show()` returns. Every failure is [NoFill]. */
public enum class FountisResult {
    /** Nothing to show (no matching study, no consent, no token, network trouble, nowhere to present). */
    NoFill,

    /** The person closed the study before finishing it, or was screened out / the study filled up. */
    Dismissed,

    /** The person finished the study. */
    Completed,
}

/**
 * Anonymous lifecycle event for the host app (`onEvent`). Carries no titles, topics or answers.
 * [type] is one of `shown`, `dismissed`, `completed`, `noFill`, `notified`.
 */
public class FountisEvent(public val type: String, public val offerId: String?) {
    override fun toString(): String = "FountisEvent($type, $offerId)"
}

/** Receives [FountisEvent]s on the main thread. */
public fun interface FountisEventListener {
    public fun onEvent(event: FountisEvent)
}

/** Java-friendly result callback for `show(activity, callback)`; called on the main thread. */
public fun interface FountisResultCallback {
    public fun onResult(result: FountisResult)
}

/**
 * Java-friendly user-token provider. Called on a background thread, so a blocking call to your server is fine.
 * Return `null` when nobody is signed in.
 */
public fun interface FountisTokenProvider {
    public fun getToken(): String?
}

// ---- internal models (parsed with org.json, no reflection) ----

internal class Condition(val attr: String, val op: String, val value: Any?)

internal class OfferReward(val mode: String, val units: Int?, val unitName: Any?) {
    val isRewarded: Boolean get() = mode == "rewarded" && (units ?: 0) > 0

    fun unitLabel(lang: String): String = when (val u = unitName) {
        is String -> u
        is Map<*, *> -> (u[lang] as? String) ?: (u["en"] as? String) ?: u.values.firstNotNullOfOrNull { it as? String } ?: ""
        else -> ""
    }
}

internal class Offer(
    val offerId: String,
    val conditions: List<Condition>,
    val requiredAttrs: List<String>,
    val loiMinutes: Int?,
    val reward: OfferReward?,
    val expiresAt: String?,
    /** Open to guests (people with no signed token); only ever true on apps FOUNTIS allowed guests in. */
    val guest: Boolean = false,
)

internal class SurveysConfig(val maxNotificationsPerDay: Int?, val quietHours: List<Int>?, val checkIntervalMinutes: Int?)

internal class SurveysResponse(
    val appName: String?,
    val config: SurveysConfig?,
    val surveys: List<Offer>,
    val guests: Boolean = false,
    /** Device attestation for guest sessions (`app.attest`); off when the server sends nothing. */
    val attest: AttestConfig = AttestConfig.OFF,
)

// ---- JSON helpers ----

/** Converts org.json values into plain Kotlin values (Map, List, String, Number, Boolean, null). */
internal fun jsonToKotlin(v: Any?): Any? = when (v) {
    null, JSONObject.NULL -> null
    is JSONObject -> v.keys().asSequence().associateWith { jsonToKotlin(v.opt(it)) }
    is JSONArray -> (0 until v.length()).map { jsonToKotlin(v.opt(it)) }
    else -> v
}

private fun JSONObject.optStringOrNull(name: String): String? =
    if (has(name) && !isNull(name)) opt(name) as? String else null

private fun JSONObject.optIntOrNull(name: String): Int? =
    if (has(name) && !isNull(name)) (opt(name) as? Number)?.toInt() else null

internal fun parseSurveys(text: String): SurveysResponse {
    val root = JSONObject(text)
    val cfg = root.optJSONObject("config")?.let { c ->
        SurveysConfig(
            maxNotificationsPerDay = c.optIntOrNull("max_notifications_per_day"),
            quietHours = c.optJSONArray("quiet_hours")?.let { a -> (0 until a.length()).map { a.optInt(it) } },
            checkIntervalMinutes = c.optIntOrNull("check_interval_minutes"),
        )
    }
    val list = root.optJSONArray("surveys") ?: JSONArray()
    val offers = ArrayList<Offer>()
    for (i in 0 until list.length()) {
        val o = list.optJSONObject(i) ?: continue
        val id = o.optStringOrNull("offer_id") ?: continue
        val conds = ArrayList<Condition>()
        o.optJSONObject("conditions")?.optJSONArray("all")?.let { all ->
            for (j in 0 until all.length()) {
                val c = all.optJSONObject(j) ?: continue
                conds.add(Condition(c.optString("attr"), c.optString("op"), jsonToKotlin(c.opt("value"))))
            }
        }
        val attrs = o.optJSONArray("required_attrs")?.let { a -> (0 until a.length()).mapNotNull { a.optString(it).ifEmpty { null } } } ?: emptyList()
        val reward = o.optJSONObject("reward")?.let { r ->
            OfferReward(r.optString("mode"), r.optIntOrNull("units"), jsonToKotlin(r.opt("unit_name")))
        }
        offers.add(Offer(id, conds, attrs, o.optIntOrNull("loi_minutes"), reward, o.optStringOrNull("expires_at"), o.optBoolean("guest", false)))
    }
    val app = root.optJSONObject("app")
    val attest = app?.optJSONObject("attest")?.let { a ->
        // The project number is a string on the wire; a bare JSON number is accepted too.
        val project = when (val p = a.opt("android_cloud_project")) {
            is String -> p
            is Number -> p.toLong().toString()
            else -> null
        }
        AttestConfig(a.optString("mode", "off"), project)
    } ?: AttestConfig.OFF
    return SurveysResponse(app?.optStringOrNull("name"), cfg, offers, app?.optBoolean("guests", false) ?: false, attest)
}

internal const val TAG = "FountisConnect"

internal fun logd(message: String) {
    try {
        android.util.Log.d(TAG, message)
    } catch (_: Throwable) {
        // plain JVM unit tests have no android.util.Log
    }
}
