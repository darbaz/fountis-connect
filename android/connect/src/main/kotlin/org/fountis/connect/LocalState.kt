package org.fountis.connect

import android.content.Context
import java.io.File
import java.util.Calendar
import java.util.GregorianCalendar
import org.json.JSONArray
import org.json.JSONObject

/**
 * One small JSON file in `noBackupFilesDir`: Android never copies that directory to cloud backup or to a new device,
 * so no backup rules are needed in the host app. Holds the notifications switch and, per person (keyed by
 * sha256(sub)), the offers already notified / dismissed / taken and the daily notification count. Never sent anywhere.
 */
internal class StateStore(context: Context) {
    private val file = File(context.applicationContext.noBackupFilesDir, "org.fountis.connect.state.json")
    private var root: JSONObject? = null

    @Synchronized
    private fun load(): JSONObject {
        root?.let { return it }
        val r = try {
            JSONObject(file.readText(Charsets.UTF_8))
        } catch (_: Exception) {
            JSONObject()
        }
        root = r
        return r
    }

    @Synchronized
    private fun save() {
        try {
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeText(load().toString(), Charsets.UTF_8)
            if (!tmp.renameTo(file)) {
                file.delete()
                tmp.renameTo(file)
            }
        } catch (e: Exception) {
            android.util.Log.d(TAG, "state not saved: $e")
        }
    }

    @Synchronized
    fun getBoolean(name: String): Boolean = load().optBoolean(name, false)

    @Synchronized
    fun setBoolean(name: String, v: Boolean) {
        load().put(name, v)
        save()
    }

    /**
     * The guest install id: 24 random bytes made on first use, kept here (never backed up, never a device identifier).
     * FOUNTIS stores only a hash of it.
     */
    @Synchronized
    fun installId(): String {
        val have = load().optString("guest.install_id", "")
        if (have.length >= 22) return have
        val bytes = ByteArray(24).also { java.security.SecureRandom().nextBytes(it) }
        val id = android.util.Base64.encodeToString(bytes, android.util.Base64.URL_SAFE or android.util.Base64.NO_PADDING or android.util.Base64.NO_WRAP)
        load().put("guest.install_id", id)
        save()
        return id
    }

    @Synchronized
    fun person(key: String): JSONObject = load().optJSONObject(key) ?: JSONObject()

    @Synchronized
    fun putPerson(key: String, v: JSONObject) {
        load().put(key, v)
        save()
    }

    @Synchronized
    fun remove(key: String) {
        load().remove(key)
        save()
    }
}

internal class LocalState(private val store: StateStore, subHash: String) {
    private val key = "s.$subHash"

    private fun list(o: JSONObject, name: String): MutableList<String> {
        val a = o.optJSONArray(name) ?: return mutableListOf()
        return (0 until a.length()).map { a.optString(it) }.toMutableList()
    }

    private fun today(): String {
        val c = GregorianCalendar()
        return "${c.get(Calendar.YEAR)}-${c.get(Calendar.MONTH) + 1}-${c.get(Calendar.DAY_OF_MONTH)}"
    }

    private fun add(id: String, name: String) {
        val o = store.person(key)
        val l = list(o, name)
        if (!l.contains(id)) l.add(id)
        while (l.size > 200) l.removeAt(0)
        o.put(name, JSONArray(l))
        store.putPerson(key, o)
    }

    fun markNotified(id: String) {
        add(id, "notified")
        val o = store.person(key)
        if (o.optString("day") != today()) {
            o.put("day", today())
            o.put("dayCount", 0)
        }
        o.put("dayCount", o.optInt("dayCount", 0) + 1)
        store.putPerson(key, o)
    }

    fun markDismissed(id: String) = add(id, "dismissed")
    fun markTaken(id: String) = add(id, "taken")

    val notificationsToday: Int
        get() {
            val o = store.person(key)
            return if (o.optString("day") == today()) o.optInt("dayCount", 0) else 0
        }

    /** For the explicit `show()`: only studies already finished are excluded. */
    fun isTaken(id: String): Boolean = list(store.person(key), "taken").contains(id)

    /** For notifications: anything the person has already seen, closed or finished. */
    fun isSuppressedForNotification(id: String): Boolean {
        val o = store.person(key)
        return list(o, "taken").contains(id) || list(o, "dismissed").contains(id) || list(o, "notified").contains(id)
    }

    /** For auto-show: finished or closed. */
    fun isSuppressedForAutoShow(id: String): Boolean {
        val o = store.person(key)
        return list(o, "taken").contains(id) || list(o, "dismissed").contains(id)
    }

    fun clear() = store.remove(key)
}
