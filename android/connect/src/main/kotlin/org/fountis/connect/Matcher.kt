package org.fountis.connect

import java.security.MessageDigest
import java.util.Calendar
import java.util.GregorianCalendar
import java.util.TimeZone
import org.json.JSONObject

/** The decoded (never verified) token payload. The server verifies everything on POST /attempts. */
internal class TokenInfo(val sub: String, val attrs: Map<String, Any?>, val expSeconds: Double?) {
    val lang: String? get() = attrs["lang"] as? String

    /**
     * Every attribute the token carries, in a fixed order, for the consent screen. FOUNTIS stores all of them when the
     * study opens, not only the ones the study's conditions use (`requiredAttrs`).
     */
    val carriedAttrs: List<String>
        get() {
            val order = listOf("gender", "birth_year", "governorate", "city", "lang")
            fun rank(k: String): Int = order.indexOf(k).let { if (it < 0) order.size else it }
            return attrs.filterValues { it != null }.keys.sortedWith(compareBy<String>({ rank(it) }, { it }))
        }

    /** First 8 bytes of sha256(sub) as hex: the key for this person's local state. */
    val subHash: String
        get() = MessageDigest.getInstance("SHA-256").digest(sub.toByteArray(Charsets.UTF_8))
            .take(8).joinToString("") { "%02x".format(it) }

    companion object {
        fun decode(token: String): TokenInfo? = try {
            val parts = token.split(".")
            if (parts.size < 2) null else {
                val o = JSONObject(String(base64UrlDecode(parts[1]), Charsets.UTF_8))
                val sub = o.optString("sub", "")
                if (sub.isEmpty()) null else TokenInfo(
                    sub,
                    (jsonToKotlin(o.optJSONObject("attrs")) as? Map<*, *>)?.entries
                        ?.associate { it.key.toString() to it.value } ?: emptyMap(),
                    if (o.has("exp") && !o.isNull("exp")) (o.opt("exp") as? Number)?.toDouble() else null,
                )
            }
        } catch (_: Exception) {
            null
        }

        /** android.util.Base64 is not available in JVM unit tests and java.util.Base64 needs API 26, so decode by hand. */
        fun base64UrlDecode(s: String): ByteArray {
            val out = java.io.ByteArrayOutputStream()
            var buf = 0
            var bits = 0
            for (ch in s) {
                val v = when (ch) {
                    in 'A'..'Z' -> ch - 'A'
                    in 'a'..'z' -> ch - 'a' + 26
                    in '0'..'9' -> ch - '0' + 52
                    '-', '+' -> 62
                    '_', '/' -> 63
                    else -> continue // padding or whitespace
                }
                buf = (buf shl 6) or v
                bits += 6
                if (bits >= 8) {
                    bits -= 8
                    out.write((buf shr bits) and 0xFF)
                }
            }
            return out.toByteArray()
        }
    }
}

internal object Matcher {
    /** Offer is offerable to this person: required attributes present, not expired, every condition holds. */
    fun matches(offer: Offer, token: TokenInfo, nowMillis: Long = System.currentTimeMillis()): Boolean {
        offer.expiresAt?.let { s -> parseDate(s)?.let { if (it < nowMillis) return false } }
        for (a in offer.requiredAttrs) if (token.attrs[a] == null) return false
        for (c in offer.conditions) if (!holds(c, token.attrs, nowMillis)) return false
        return true
    }

    /** Offer is offerable to a guest: the server marked it guest-eligible and it has not expired. */
    fun matchesGuest(offer: Offer, nowMillis: Long = System.currentTimeMillis()): Boolean {
        if (!offer.guest) return false
        offer.expiresAt?.let { s -> parseDate(s)?.let { if (it < nowMillis) return false } }
        return true
    }

    private fun yearOf(nowMillis: Long): Int =
        GregorianCalendar().apply { timeInMillis = nowMillis }.get(Calendar.YEAR)

    fun attrValue(name: String, attrs: Map<String, Any?>, nowMillis: Long): Any? {
        if (name == "age") {
            val by = (attrs["birth_year"] as? Number)?.toInt() ?: return null
            return yearOf(nowMillis) - by
        }
        return attrs[name]
    }

    private fun str(v: Any?): String? = when (v) {
        is String -> v
        is Number -> if (v.toDouble() == Math.floor(v.toDouble()) && !v.toDouble().isInfinite()) v.toLong().toString() else v.toString()
        is Boolean -> v.toString()
        else -> null
    }

    private fun num(v: Any?): Double? = when (v) {
        is Number -> v.toDouble()
        is String -> v.toDoubleOrNull()
        else -> null
    }

    fun holds(c: Condition, attrs: Map<String, Any?>, nowMillis: Long): Boolean {
        val v = attrValue(c.attr, attrs, nowMillis) ?: return false
        val s = str(v) ?: ""
        val n = num(v)
        fun same(x: Any?): Boolean = str(x) == s || (num(x) != null && num(x) == n)
        return when (c.op) {
            "in", "not_in" -> {
                val list = c.value as? List<*> ?: return false
                val hit = list.any { same(it) }
                if (c.op == "in") hit else !hit
            }
            "eq" -> same(c.value)
            "gte" -> n != null && num(c.value) != null && n >= num(c.value)!!
            "lte" -> n != null && num(c.value) != null && n <= num(c.value)!!
            "between" -> {
                val r = c.value as? List<*> ?: return false
                if (r.size != 2) return false
                val lo = num(r[0]) ?: return false
                val hi = num(r[1]) ?: return false
                n != null && n >= lo && n <= hi
            }
            else -> false
        }
    }

    private val ISO = Regex("""^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}(?::?\d{2})?)?$""")

    /** ISO 8601 to epoch millis, by hand: SimpleDateFormat's `X` needs API 24 and java.time needs API 26. */
    fun parseDate(s: String): Long? {
        val m = ISO.matchEntire(s.trim()) ?: return null
        val g = m.groupValues
        val cal = GregorianCalendar(TimeZone.getTimeZone("UTC"))
        cal.clear()
        cal.set(g[1].toInt(), g[2].toInt() - 1, g[3].toInt(), g[4].toInt(), g[5].toInt(), g[6].toInt())
        var ms = cal.timeInMillis
        val z = g[7]
        if (z.isNotEmpty() && z != "Z") {
            val sign = if (z[0] == '-') -1 else 1
            val digits = z.substring(1).replace(":", "")
            val h = digits.substring(0, 2).toInt()
            val min = if (digits.length >= 4) digits.substring(2, 4).toInt() else 0
            ms -= sign * (h * 60L + min) * 60_000L
        }
        return ms
    }

    /** `quiet = [start, end]` hours in local time, wrapping midnight (e.g. [22, 9]). */
    fun inQuietHours(quiet: List<Int>?, nowMillis: Long = System.currentTimeMillis()): Boolean {
        if (quiet == null || quiet.size != 2) return false
        val h = GregorianCalendar().apply { timeInMillis = nowMillis }.get(Calendar.HOUR_OF_DAY)
        val s = quiet[0]
        val e = quiet[1]
        if (s == e) return false
        return if (s < e) h >= s && h < e else h >= s || h < e
    }
}
