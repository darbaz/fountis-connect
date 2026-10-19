package org.fountis.connect

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import java.lang.ref.WeakReference
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/**
 * FOUNTIS Connect for Android.
 *
 * ```kotlin
 * // In Application.onCreate (not in an Activity):
 * FountisConnect.start(this, "pk_live_...")
 * FountisConnect.setUserToken { myServer.fountisToken() }   // null when signed out
 * // Later, from an Activity (optional):
 * FountisConnect.enableNotifications(this)
 * ```
 *
 * Guests: when the token provider returns `null` (nobody is signed in) and FOUNTIS has switched guests on for your
 * app, the SDK offers the free studies marked open to guests, after an 18+ confirmation. Nothing to call; an app
 * without accounts can pass `setUserToken { null }`. When FOUNTIS asks for it, a guest's device is also checked with
 * Google Play Integrity (link your app to the FOUNTIS Google Cloud project in Play Console); an app installed outside
 * Google Play works too, the check then just reports that it is unavailable.
 *
 * Every failure is silent and becomes [FountisResult.NoFill] plus a `Log.d` line with the tag `FountisConnect`.
 * The SDK never throws into the host app.
 */
public object FountisConnect {
    /** Production base URL until `api.fountis.org` is live. */
    public const val DEFAULT_API_BASE: String = "https://ucclsekjekdxzfwzyuji.supabase.co/functions/v1/connect-api/v1"

    /**
     * Starts the SDK. Call once, from `Application.onCreate`, so the background check also works when the
     * process is started by the system. [apiBase] defaults to [DEFAULT_API_BASE].
     */
    @JvmStatic
    @JvmOverloads
    public fun start(context: Context, key: String, apiBase: String? = null) {
        guarded { Core.start(context, key, apiBase ?: DEFAULT_API_BASE) }
    }

    /**
     * Gives the SDK a way to get the signed user token from your server. Return `null` only when nobody is signed
     * in; that is the one case the SDK treats as a guest. Throw when you cannot get a token (offline, server error):
     * the SDK shows nothing and tries again later. No answer within 10 seconds counts as a failure too (nothing is
     * shown, and the person is never treated as a guest). An empty string is not "signed out": it is an unusable
     * token and shows nothing.
     * Called on demand, never cached by the SDK for longer than one check.
     */
    @JvmStatic
    public fun setUserToken(provider: suspend () -> String?) {
        guarded { Core.setUserToken(provider) }
    }

    /**
     * Java variant of [setUserToken]: [provider] runs on a background thread, so a blocking call is fine. Return
     * `null` only when nobody is signed in; throw when you cannot get a token. A call that has not returned after
     * 10 seconds counts as a failure (nothing is shown, never a guest).
     */
    @JvmStatic
    public fun setUserTokenProvider(provider: FountisTokenProvider) {
        guarded { Core.setUserToken { withContext(Dispatchers.IO) { provider.getToken() } } }
    }

    /**
     * Turns on the background check (WorkManager, about every 4 hours) and asks for the notification permission on
     * Android 13+ if it is not already granted. One local notification a day at most.
     */
    @JvmStatic
    public fun enableNotifications(activity: Activity) {
        guarded { Core.enableNotifications(activity) }
    }

    /** Looks for a matching study and shows it full screen. Returns [FountisResult.NoFill] fast when there is nothing to show. */
    @JvmStatic
    public suspend fun show(activity: Activity): FountisResult = try {
        withContext(Dispatchers.Main.immediate) { Core.run(Mode.Manual, activity) }
    } catch (e: CancellationException) {
        throw e
    } catch (t: Throwable) {
        logd("show failed: $t")
        FountisResult.NoFill
    }

    /** Callback variant of [show] for Java; [callback] runs on the main thread. */
    @JvmStatic
    public fun show(activity: Activity, callback: FountisResultCallback) {
        guarded {
            Core.scope.launch {
                val r = show(activity)
                try {
                    callback.onResult(r)
                } catch (t: Throwable) {
                    logd("callback failed: $t")
                }
            }
        }
    }

    /** Call from your push handler with the message data. Returns `true` if it is a FOUNTIS push (it carries a `fountis` key). */
    @JvmStatic
    public fun handlePush(data: Map<String, String>): Boolean = guarded(false) { Core.handlePush(data) }

    /**
     * The notification tap opens your app's launcher activity with an extra. The SDK picks it up by itself when an
     * activity resumes; call this from `onNewIntent` if your launcher activity is `singleTop`/`singleTask`.
     * Returns `true` (and presents the study) if the intent came from a FOUNTIS notification.
     */
    @JvmStatic
    public fun handleIntent(intent: Intent?): Boolean = guarded(false) { Core.handleIntent(intent) }

    /** Pass the person's consent to be offered studies (for example from your own consent screen). Default: `true`. */
    @JvmStatic
    public fun setUserConsent(granted: Boolean) {
        Core.consent = granted
    }

    /** Forget the signed-in person: removes this person's local state and any posted notification. */
    @JvmStatic
    public fun signOut() {
        guarded { Core.signOut() }
    }

    /** Anonymous lifecycle events (`shown`, `dismissed`, `completed`, `noFill`, `notified`), delivered on the main thread. */
    @JvmStatic
    public fun onEvent(listener: FountisEventListener) {
        Core.listeners.add(listener)
    }

    private inline fun guarded(block: () -> Unit) {
        try {
            block()
        } catch (t: Throwable) {
            logd("failed: $t")
        }
    }

    private inline fun <T> guarded(fallback: T, block: () -> T): T = try {
        block()
    } catch (t: Throwable) {
        logd("failed: $t")
        fallback
    }
}

internal sealed class Mode {
    object Manual : Mode()
    object Auto : Mode()
    class Offer(val id: String) : Mode()
}

internal object Core {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile var consent = true
    val listeners = CopyOnWriteArrayList<FountisEventListener>()

    private var app: Application? = null
    private var api: ApiClient? = null
    private var store: StateStore? = null

    @Volatile private var provider: (suspend () -> String?)? = null
    @Volatile private var started = false
    @Volatile private var foreground = false
    private var presenting = false
    private var autoShownThisSession = false
    // Set when run() refused to present because no activity was in front (the notification permission dialog pauses
    // the host activity) or the app was not in the foreground. An auto-show that hits this is given back, not spent.
    @Volatile private var skippedWhileInactive = false
    private var autoJob: Job? = null
    private var backgroundedAt = 0L
    private var notificationsOn = false
    private var lastSubHash: String? = null
    private var guestSession: Pair<String, Long>? = null
    private var guestAttest: GuestAttestation? = null
    // Attests (when the app asks for it) and opens the guest session; after a refusal it sends nothing for 10 minutes.
    private val guestOpener = GuestSessionOpener({ attestation() })
    // Where Play Integrity is prepared (a few seconds, once per process). Never the main thread, never cancelled.
    private val attestScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var resumed: WeakReference<Activity>? = null
    private var webViewOk: Boolean? = null
    private var cache: Cached? = null

    private class Cached(val lang: String, val at: Long, val value: SurveysResponse)

    private class Session(
        val api: ApiClient,
        /** The signed user token; null for a guest. */
        val token: String?,
        val info: TokenInfo?,
        val lang: String,
        val surveys: SurveysResponse,
        val state: LocalState,
    ) {
        val isGuest: Boolean get() = token == null

        fun matches(offer: Offer): Boolean = if (info != null) Matcher.matches(offer, info) else Matcher.matchesGuest(offer)
    }

    private const val ACCENT = "#5dc0a0"
    private const val PERMISSION_REQUEST_CODE = 4670

    // ---- setup ----

    fun start(context: Context, key: String, apiBase: String) {
        val a = context.applicationContext as? Application ?: return
        synchronized(this) {
            if (started) return
            if (!key.startsWith("pk_")) {
                logd("start: key must be a publishable key (pk_...)")
                return
            }
            val st = StateStore(a)
            app = a
            api = ApiClient(apiBase, key)
            store = st
            notificationsOn = st.getBoolean("notifications")
            a.registerActivityLifecycleCallbacks(callbacks)
            started = true
        }
        mainHandler.post {
            try {
                ProcessLifecycleOwner.get().lifecycle.addObserver(processObserver)
            } catch (t: Throwable) {
                logd("lifecycle observer failed: $t")
            }
        }
        if (notificationsOn) {
            Notifier.ensureChannel(a)
            Notifier.schedule(a, null)
        }
    }

    fun setUserToken(p: suspend () -> String?) {
        provider = p
        mainHandler.post { if (started && foreground) scheduleAutoShow() }
    }

    fun enableNotifications(activity: Activity) {
        val a = app
        val st = store
        if (!started || a == null || st == null) {
            logd("enableNotifications: call start() first")
            return
        }
        notificationsOn = true
        st.setBoolean("notifications", true)
        Notifier.ensureChannel(a)
        activity.runOnUiThread {
            try {
                if (Build.VERSION.SDK_INT >= 33 &&
                    activity.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                ) {
                    ActivityCompat.requestPermissions(activity, arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), PERMISSION_REQUEST_CODE)
                }
            } catch (t: Throwable) {
                logd("permission request failed: $t")
            }
        }
        Notifier.schedule(a, cache?.value?.config?.checkIntervalMinutes)
    }

    fun signOut() {
        mainHandler.post {
            autoJob?.cancel()
            val st = store
            lastSubHash?.let { h -> st?.let { LocalState(it, h).clear() } }
            lastSubHash = null
            guestSession = null
            cache = null
            autoShownThisSession = false
            app?.let { Notifier.cancel(it) }
        }
    }

    // ---- foreground / activities / push / tap ----

    private val processObserver = object : DefaultLifecycleObserver {
        override fun onStart(owner: LifecycleOwner) {
            foreground = true
            if (backgroundedAt != 0L && System.currentTimeMillis() - backgroundedAt > 1_800_000L) autoShownThisSession = false
            backgroundedAt = 0L
            scheduleAutoShow()
        }

        override fun onStop(owner: LifecycleOwner) {
            foreground = false
            backgroundedAt = System.currentTimeMillis()
        }
    }

    private val callbacks = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityResumed(activity: Activity) {
            if (activity is FountisSurveyActivity) return
            resumed = WeakReference(activity)
            // The notification permission dialog pauses the host activity. An auto-show that found no resumed
            // activity gave up without being consumed, so try again as soon as one is back in front.
            if (started) scheduleAutoShow()
            try {
                val id = activity.intent?.getStringExtra(Notifier.EXTRA_OFFER)
                if (id != null) {
                    activity.intent.removeExtra(Notifier.EXTRA_OFFER)
                    handleTap(id)
                }
            } catch (t: Throwable) {
                logd("intent check failed: $t")
            }
        }

        override fun onActivityPaused(activity: Activity) {
            if (resumed?.get() === activity) resumed = null
        }

        override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
        override fun onActivityStarted(activity: Activity) {}
        override fun onActivityStopped(activity: Activity) {}
        override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
        override fun onActivityDestroyed(activity: Activity) {}
    }

    private fun topActivity(): Activity? = resumed?.get()?.takeIf { !it.isFinishing && !it.isDestroyed }

    private fun scheduleAutoShow() {
        if (autoShownThisSession || provider == null || !started) return
        autoJob?.cancel()
        autoJob = scope.launch {
            delay(1200) // let the host UI settle
            if (autoShownThisSession || !foreground) return@launch
            val act = topActivity() ?: return@launch
            autoShownThisSession = true
            skippedWhileInactive = false
            val result = run(Mode.Auto, act)
            // The dialog can also appear while the request is in flight; run() then refuses to present. Give the
            // auto-show back and try again once an activity is resumed again.
            if (result == FountisResult.NoFill && skippedWhileInactive) {
                autoShownThisSession = false
                if (foreground && topActivity() != null) scheduleAutoShow()
            }
        }
    }

    fun handlePush(data: Map<String, String>): Boolean {
        if (!data.containsKey("fountis")) return false
        scope.launch {
            try {
                if (foreground) run(Mode.Auto, topActivity()) else checkAndNotify()
            } catch (e: CancellationException) {
                throw e
            } catch (t: Throwable) {
                logd("push check failed: $t")
            }
        }
        return true
    }

    fun handleIntent(intent: Intent?): Boolean {
        val id = intent?.getStringExtra(Notifier.EXTRA_OFFER) ?: return false
        intent.removeExtra(Notifier.EXTRA_OFFER)
        handleTap(id)
        return true
    }

    private fun handleTap(offerId: String) {
        scope.launch {
            // cold start: wait (briefly) for the app to be in front with an activity to present from
            for (i in 0 until 20) {
                if (foreground && topActivity() != null) break
                delay(250)
            }
            autoShownThisSession = true
            run(Mode.Offer(offerId), topActivity())
        }
    }

    // ---- data ----

    private suspend fun fetchSurveys(api: ApiClient, lang: String): SurveysResponse {
        cache?.let { if (it.lang == lang && System.currentTimeMillis() - it.at < 60_000) return it.value }
        val r = api.surveys(lang)
        cache = Cached(lang, System.currentTimeMillis(), r)
        return r
    }

    private fun emit(type: String, offerId: String? = null) {
        val e = FountisEvent(type, offerId)
        for (l in listeners) {
            try {
                l.onEvent(e)
            } catch (t: Throwable) {
                logd("listener failed: $t")
            }
        }
    }

    private suspend fun openSession(): Session? {
        val api = api
        val provider = provider
        val st = store
        if (!started || !consent || api == null || provider == null || st == null) return null
        return try {
            // Only null means nobody is signed in. A throw or no answer in 10 s is a failure (noFill), never a guest.
            val token = callTokenProvider(scope) { provider() } ?: return openGuestSession(api, st)
            // An empty string is not "signed out": it is an unusable token. (decode returns null for it anyway.)
            if (token.isEmpty()) return null
            val info = TokenInfo.decode(token) ?: return null
            if (info.expSeconds != null && info.expSeconds < System.currentTimeMillis() / 1000.0) return null
            lastSubHash = info.subHash
            val lang = info.lang?.let { Strings.normalize(it) } ?: Strings.deviceLang()
            Session(api, token, info, lang, fetchSurveys(api, lang), LocalState(st, info.subHash))
        } catch (e: CancellationException) {
            throw e
        } catch (e: TokenProviderTimeoutException) {
            logd("token provider gave no answer within ${TOKEN_PROVIDER_TIMEOUT_MS / 1000} s")
            null
        } catch (t: Throwable) {
            logd("check failed: $t")
            null
        }
    }

    /** Nobody is signed in: a guest session, only when the app allows guests and a guest study exists. */
    private suspend fun openGuestSession(api: ApiClient, st: StateStore): Session? {
        val lang = Strings.deviceLang()
        val surveys = fetchSurveys(api, lang)
        if (!surveys.guests || surveys.surveys.none { it.guest }) return null
        // Get Play Integrity ready early, but only for a guest who can see a study now (not for the background check).
        if (surveys.attest.isOn && foreground) attestation()?.warmUp(surveys.attest)
        lastSubHash = "guest"
        return Session(api, null, null, lang, surveys, LocalState(st, "guest"))
    }

    /** The Play Integrity side of guest attestation; made only once an app asks for it (mode `report` or `enforce`). */
    private fun attestation(): GuestAttestation? {
        val a = app ?: return null
        return synchronized(this) { guestAttest ?: GuestAttestation(PlayIntegrityAttestor(a), attestScope).also { guestAttest = it } }
    }

    /**
     * A guest session token, kept in memory for most of its hour. `force` makes a new one.
     * Only here, right before a new guest session, the device is attested (when the app's mode asks for it).
     * After a refusal (403 `attestation_required` / `attestation_failed`) nothing is sent for 10 minutes: every attempt
     * ends as that refusal, so a device FOUNTIS will turn away again does not spend a Play Integrity token on each show().
     */
    private suspend fun guestToken(s: Session, force: Boolean = false): String {
        val st = store ?: throw ApiError(0, "not_started", "not started")
        guestSession?.let { if (!force && it.second > System.currentTimeMillis()) return it.first }
        val t = guestOpener.open(s.api, s.surveys.attest, st.installId())
        guestSession = t to (System.currentTimeMillis() + 55 * 60_000L)
        return t
    }

    /** Starts the attempt for a person with a token or a guest session (a stale guest session is renewed once). */
    private suspend fun createAttempt(s: Session, offerId: String): JSONObject {
        if (s.token != null) return s.api.createAttempt(offerId, s.token, s.lang)
        return try {
            s.api.createGuestAttempt(offerId, guestToken(s), s.lang)
        } catch (e: ApiError) {
            if (e.code != "invalid_session") throw e
            s.api.createGuestAttempt(offerId, guestToken(s, force = true), s.lang)
        }
    }

    // ---- show ----

    suspend fun run(mode: Mode, activity: Activity?): FountisResult {
        val result = try {
            runInner(mode, activity)
        } catch (e: CancellationException) {
            throw e
        } catch (t: Throwable) {
            logd("run failed: $t")
            FountisResult.NoFill
        }
        if (result == FountisResult.NoFill) emit("noFill")
        return result
    }

    private suspend fun runInner(mode: Mode, activity: Activity?): FountisResult {
        if (presenting) return FountisResult.NoFill
        presenting = true
        try {
            val s = openSession() ?: return FountisResult.NoFill
            val act = (activity ?: topActivity())?.takeIf { !it.isFinishing && !it.isDestroyed }
            if (act == null) { skippedWhileInactive = true; return FountisResult.NoFill }
            if (mode !is Mode.Manual && !foreground) { skippedWhileInactive = true; return FountisResult.NoFill }
            val ok = webViewOk ?: WebViewSupport.isSupported(act).also { webViewOk = it }
            if (!ok) {
                logd("WebView missing or older than Chromium 88")
                return FountisResult.NoFill
            }

            var offers = s.surveys.surveys.filter { s.matches(it) }
            offers = when (mode) {
                is Mode.Manual -> offers.filter { !s.state.isTaken(it.offerId) }
                is Mode.Auto -> offers.filter { !s.state.isSuppressedForAutoShow(it.offerId) }
                is Mode.Offer -> offers.filter { it.offerId == mode.id && !s.state.isTaken(it.offerId) }
            }
            // Rewarded first (the sort is stable).
            offers = offers.sortedByDescending { it.reward?.isRewarded == true }

            for (offer in offers.take(3)) {
                try {
                    val a = createAttempt(s, offer.offerId)
                    return present(offer, a, s, act)
                } catch (e: ApiError) {
                    if (e.isAttestationRefusal) {
                        // FOUNTIS could not vouch for this device: no guest studies this time, and no retry.
                        logd("guest studies not offered: ${e.code}")
                        return FountisResult.NoFill
                    }
                    if (e.code == "already_taken") s.state.markTaken(offer.offerId)
                    if (e.code in setOf("already_taken", "not_eligible", "closed", "quota_full", "guests_not_allowed")) continue
                    logd("attempt failed: ${e.code}")
                    return FountisResult.NoFill
                } catch (e: CancellationException) {
                    throw e
                } catch (t: Throwable) {
                    logd("attempt failed: $t")
                    return FountisResult.NoFill
                }
            }
            return FountisResult.NoFill
        } finally {
            presenting = false
        }
    }

    private suspend fun present(offer: Offer, a: JSONObject, s: Session, activity: Activity): FountisResult {
        val attemptToken = a.optString("attempt_token", "")
        if (attemptToken.isEmpty() || !a.has("definition")) return FountisResult.NoFill

        val payload = JSONObject()
            .put("mode", "native")
            .put("definition", a.opt("definition") ?: JSONObject.NULL)
            .put("answers", a.optJSONObject("answers") ?: JSONObject())
            .put("lang", s.lang)
            .put("rtl", Strings.isRtl(s.lang))
            .put("theme", JSONObject().put("accent", ACCENT))
            .put("consentNeeded", a.optBoolean("consent_needed", false))
            .put("attrs", JSONArray(s.info?.carriedAttrs ?: emptyList<String>()))
        if (s.isGuest || a.optBoolean("guest", false)) payload.put("guest", true)
        s.surveys.appName?.let { payload.put("partner", it) }
        a.optString("rid", "").takeIf { it.isNotEmpty() }?.let { payload.put("rid", it) }
        a.optJSONObject("reward")?.let { r ->
            if (r.optInt("units", 0) > 0) {
                payload.put("reward", JSONObject().put("units", r.optInt("units", 0)).put("unit_name", r.opt("unit_name") ?: ""))
            }
        }

        val done = CompletableDeferred<Finish>()
        val pending = SurveyPending(payload.toString(), s.api, attemptToken) { done.complete(it) }
        pending.onShown = {
            emit("shown", offer.offerId)
            scope.launch { s.api.event(offer.offerId, "shown") }
        }
        SurveyHost.pending = pending
        try {
            activity.startActivity(Intent(activity, FountisSurveyActivity::class.java))
        } catch (t: Throwable) {
            logd("could not open the study: $t")
            SurveyHost.pending = null
            return FountisResult.NoFill
        }
        scope.launch {
            delay(10_000)
            if (!pending.attached) {
                if (SurveyHost.pending === pending) SurveyHost.pending = null
                done.complete(Finish(null, null, unavailable = true))
            }
        }

        val fin = done.await()
        if (fin.unavailable) return FountisResult.NoFill
        return if (fin.outcome == "complete") {
            s.state.markTaken(offer.offerId)
            emit("completed", offer.offerId)
            FountisResult.Completed
        } else {
            if (fin.outcome == "screen_out" || fin.fatal == "already_taken") s.state.markTaken(offer.offerId) else s.state.markDismissed(offer.offerId)
            emit("dismissed", offer.offerId)
            scope.launch { s.api.event(offer.offerId, "dismissed") }
            FountisResult.Dismissed
        }
    }

    // ---- notifications ----

    /** Background / push check: at most one local notification a day, never in quiet hours, never while the app is in front. */
    suspend fun checkAndNotify() {
        withContext(Dispatchers.Main.immediate) { checkAndNotifyInner() }
    }

    private suspend fun checkAndNotifyInner() {
        val a = app ?: return
        if (!notificationsOn) return
        val s = openSession() ?: return
        val cfg = s.surveys.config
        if (foreground) return // foreground uses auto-show
        if (Matcher.inQuietHours(cfg?.quietHours)) return
        if (s.state.notificationsToday >= minOf(maxOf(cfg?.maxNotificationsPerDay ?: 1, 0), 1)) return
        if (!Notifier.permissionGranted(a)) return
        val offer = s.surveys.surveys.firstOrNull { s.matches(it) && !s.state.isSuppressedForNotification(it.offerId) } ?: return

        Notifier.ensureChannel(a)
        val title = Strings.get(a, "connect.notify.title", s.lang)
        val minutes = maxOf(offer.loiMinutes ?: 5, 1).toString()
        val r = offer.reward
        val body = if (r != null && r.isRewarded) {
            Strings.get(a, "connect.notify.bodyReward", s.lang, mapOf("minutes" to minutes, "units" to (r.units ?: 0).toString(), "unit" to r.unitLabel(s.lang)))
        } else {
            Strings.get(a, "connect.notify.body", s.lang, mapOf("minutes" to minutes))
        }
        if (Notifier.post(a, title, body, offer.offerId)) {
            s.state.markNotified(offer.offerId)
            emit("notified", offer.offerId)
        }
    }
}
