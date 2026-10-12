package org.fountis.connect

import android.app.Activity
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.webkit.WebMessageCompat
import androidx.webkit.WebViewAssetLoader
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import org.json.JSONObject

/** How a study screen ended. */
internal class Finish(
    /** "complete", "screen_out", "quota_full", or null when closed before the end. */
    val outcome: String?,
    /** A fatal API code (not_eligible, closed, ...) was shown. */
    val fatal: String?,
    /** The WebView could not be created; nothing was shown. */
    val unavailable: Boolean = false,
)

/** What the SDK hands to the activity (the activity cannot receive these through an Intent). */
internal class SurveyPending(
    val initJson: String,
    val api: ApiClient,
    val attemptToken: String,
    val onFinish: (Finish) -> Unit,
) {
    /** The activity started (stops the SDK's start-up timeout). */
    @Volatile var attached = false

    /** The WebView exists and the study is on screen. */
    @Volatile var onShown: (() -> Unit)? = null
}

internal object SurveyHost {
    @Volatile var pending: SurveyPending? = null
}

internal object WebViewSupport {
    /**
     * The survey screens are built for Chromium 88 (January 2021): flex gap (84), aspect-ratio and :is/:where (88).
     * On Chromium 83 (the WebView on a stock API 30 emulator) the screens load but lose all their spacing, so an older
     * WebView gets a quiet noFill instead of a broken survey. Phones update WebView through Google Play.
     */
    private const val ORIGIN_MIN_CHROMIUM = 88

    /** WebView present, new enough (Chromium 88+) and able to do `addWebMessageListener`. */
    fun isSupported(context: android.content.Context): Boolean = try {
        val pkg = WebViewCompat.getCurrentWebViewPackage(context)
        val major = pkg?.versionName?.substringBefore('.')?.toIntOrNull()
        (major == null || major >= ORIGIN_MIN_CHROMIUM) &&
            WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)
    } catch (t: Throwable) {
        logd("webview check failed: $t")
        false
    }
}

/**
 * The full-screen FOUNTIS study. Hosts the bundled survey engine in a locked-down WebView
 * (served from assets over `https://appassets.androidplatform.net`, no file or content access, every other
 * navigation blocked) and relays the engine's messages to the API; the engine itself never touches the network
 * in native mode. Opened only by the SDK.
 */
public class FountisSurveyActivity : Activity() {
    private companion object {
        const val ORIGIN = "https://appassets.androidplatform.net"
        const val ENGINE_URL = "$ORIGIN/assets/fountis-connect/engine.html"
        val PAGE_COLOR = Color.parseColor("#F2F5F4")
    }

    private var pending: SurveyPending? = null
    private var webView: WebView? = null
    private var scope: CoroutineScope? = null
    private val inFlight = HashSet<String>()
    private var outcome: String? = null
    private var fatal: String? = null
    private var finished = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The survey is hidden from screenshots, recents and screen sharing. Only a debuggable host app (never a
        // release build) may be captured, so CI can screenshot the sample on an emulator.
        val debuggable = (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
        if (!debuggable) window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
        val p = SurveyHost.pending
        SurveyHost.pending = null
        if (p == null) { // process was recreated: nothing to show
            finish()
            return
        }
        pending = p
        p.attached = true
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

        WindowCompat.setDecorFitsSystemWindows(window, false)
        val root = FrameLayout(this)
        root.setBackgroundColor(PAGE_COLOR)
        ViewCompat.setOnApplyWindowInsetsListener(root) { v, insets ->
            val b = insets.getInsets(
                WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout() or WindowInsetsCompat.Type.ime(),
            )
            v.setPadding(b.left, b.top, b.right, b.bottom)
            WindowInsetsCompat.CONSUMED
        }
        val wv = try {
            createWebView()
        } catch (t: Throwable) {
            logd("WebView unavailable: $t")
            finishWith(Finish(null, null, unavailable = true))
            return
        }
        webView = wv
        root.addView(wv, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        setContentView(root)
        p.onShown?.invoke()
        WindowCompat.getInsetsController(window, root).apply {
            isAppearanceLightStatusBars = true
            isAppearanceLightNavigationBars = true
        }
        if (Build.VERSION.SDK_INT >= 33) {
            onBackInvokedDispatcher.registerOnBackInvokedCallback(android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT) { close() }
        }
        wv.loadUrl(ENGINE_URL)
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        close() // back equals close
    }

    override fun onDestroy() {
        webView?.let {
            (it.parent as? ViewGroup)?.removeView(it)
            it.stopLoading()
            it.destroy()
        }
        webView = null
        scope?.cancel()
        finishWith(Finish(outcome, fatal)) // no-op when already finished
        super.onDestroy()
    }

    // ---- web view ----

    private fun createWebView(): WebView {
        val wv = WebView(this)
        wv.setBackgroundColor(PAGE_COLOR)
        wv.overScrollMode = View.OVER_SCROLL_NEVER
        val s = wv.settings
        s.javaScriptEnabled = true
        s.domStorageEnabled = false
        s.allowFileAccess = false
        s.allowContentAccess = false
        s.javaScriptCanOpenWindowsAutomatically = false
        s.setSupportMultipleWindows(false)
        s.setSupportZoom(false)
        s.builtInZoomControls = false
        s.mediaPlaybackRequiresUserGesture = true
        s.mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
        s.setGeolocationEnabled(false)

        val loader = WebViewAssetLoader.Builder()
            .addPathHandler("/assets/", WebViewAssetLoader.AssetsPathHandler(this))
            .build()
        wv.webViewClient = object : WebViewClient() {
            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? =
                loader.shouldInterceptRequest(request.url)

            // The engine is loaded with loadUrl(); every navigation it asks for after that is refused.
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean = true

            override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                logd("web content process gone")
                close()
                return true
            }
        }
        // Never addJavascriptInterface: the bridge is a web message listener limited to the asset-loader origin.
        WebViewCompat.addWebMessageListener(wv, "FountisBridge", setOf(ORIGIN)) { _, message, sourceOrigin, isMainFrame, _ ->
            if (isMainFrame && sourceOrigin.toString() == ORIGIN) onEngineMessage(message)
        }
        return wv
    }

    // ---- engine messages (same flow as the iOS SheetController) ----

    private fun onEngineMessage(message: WebMessageCompat) {
        try {
            val body = JSONObject(message.data ?: return)
            when (body.optString("type")) {
                "ready" -> send("window.FountisEngine && window.FountisEngine.init(${safeJs(pending?.initJson ?: "{}")})")
                "answer" -> {
                    val code = body.optString("code", "")
                    if (code.isNotEmpty()) handleAnswer(code, body.opt("value"))
                }
                "consent" -> handleConsent()
                "complete" -> handleComplete()
                "done" -> body.optString("outcome", "").takeIf { it.isNotEmpty() }?.let { outcome = it }
                "close" -> close()
                else -> Unit // progress, height: nothing to do on the host
            }
        } catch (t: Throwable) {
            logd("bad engine message: $t")
        }
    }

    /** JSON is valid JS except for U+2028/U+2029 inside strings on older engines. */
    private fun safeJs(json: String): String = json.replace("\u2028", "\\u2028").replace("\u2029", "\\u2029")

    private fun send(js: String) {
        try {
            webView?.evaluateJavascript(js, null)
        } catch (t: Throwable) {
            logd("evaluateJavascript failed: $t")
        }
    }

    private fun reply(obj: JSONObject) = send("window.FountisEngine && window.FountisEngine.receive(${safeJs(obj.toString())})")

    private fun fail(error: Throwable) {
        if (error is ApiError) {
            if (error.isFatal) fatal = error.code
            reply(JSONObject().put("type", "error").put("message", error.message).put("code", error.code))
        } else {
            reply(JSONObject().put("type", "error").put("message", "network"))
        }
    }

    /** Runs [work] unless the same request is already in flight (the engine re-sends every 5 s). */
    private fun once(key: String, work: suspend () -> Unit) {
        if (!inFlight.add(key)) return
        scope?.launch {
            try {
                work()
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (t: Throwable) {
                fail(t)
            } finally {
                inFlight.remove(key)
            }
        } ?: inFlight.remove(key)
    }

    private fun jsonValue(v: Any?): Any? = when (v) {
        null -> JSONObject.NULL
        else -> v
    }

    private fun handleAnswer(code: String, value: Any?) {
        val p = pending ?: return
        val sig = "a:$code:" + jsonValue(value).toString()
        once(sig) {
            val r = p.api.putAnswer(code, jsonValue(value), p.attemptToken)
            reply(JSONObject().put("type", "ack").put("code", code).put("stop", r.opt("stop") ?: JSONObject.NULL))
        }
    }

    private fun handleConsent() {
        val p = pending ?: return
        once("consent") {
            p.api.consent(p.attemptToken)
            reply(JSONObject().put("type", "ack").put("code", "consent").put("stop", JSONObject.NULL))
        }
    }

    private fun handleComplete() {
        val p = pending ?: return
        once("complete") {
            val r = p.api.complete(p.attemptToken)
            val o = r.optString("outcome", "complete")
            outcome = o
            reply(JSONObject().put("type", "result").put("outcome", o).put("reward", r.opt("reward") ?: JSONObject.NULL))
        }
    }

    // ---- finishing ----

    private fun close() {
        finishWith(Finish(outcome, fatal))
        if (!isFinishing) finish()
    }

    private fun finishWith(f: Finish) {
        if (finished) return
        finished = true
        val p = pending
        pending = null
        if (p == null) {
            finish()
            return
        }
        try {
            p.onFinish(f)
        } catch (t: Throwable) {
            logd("finish callback failed: $t")
        }
        if (!isFinishing) finish()
    }
}
