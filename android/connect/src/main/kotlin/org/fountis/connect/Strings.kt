package org.fountis.connect

import android.content.Context
import java.util.Locale
import org.json.JSONObject

/** Reads the shared i18n JSON (the same files the engine uses, copied into assets) for the few host-side strings. */
internal object Strings {
    private const val DIR = "fountis-connect/i18n"
    private val cache = HashMap<String, Map<String, String>>()

    @Synchronized
    private fun table(context: Context, lang: String): Map<String, String> {
        cache[lang]?.let { return it }
        val t = HashMap<String, String>()
        try {
            val text = context.applicationContext.assets.open("$DIR/$lang.json").bufferedReader(Charsets.UTF_8).use { it.readText() }
            val o = JSONObject(text)
            for (k in o.keys()) (o.opt(k) as? String)?.let { t[k] = it }
        } catch (_: Exception) {
        }
        cache[lang] = t
        return t
    }

    fun get(context: Context, key: String, lang: String, vars: Map<String, String> = emptyMap()): String {
        var s = table(context, lang)[key] ?: table(context, "en")[key] ?: key
        for ((k, v) in vars) s = s.replace("{$k}", v)
        return s
    }

    fun normalize(lang: String?): String {
        val l = lang?.lowercase(Locale.ROOT) ?: return "en"
        val two = when {
            l.startsWith("kmr") -> "kmr"
            l.startsWith("ckb") -> "ku"
            else -> l.take(2)
        }
        return if (two in setOf("en", "ku", "kmr", "ar")) two else "en"
    }

    fun isRtl(lang: String): Boolean = lang in setOf("ku", "kmr", "ar")

    fun deviceLang(): String = normalize(Locale.getDefault().toLanguageTag())
}
