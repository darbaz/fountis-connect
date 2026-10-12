package org.fountis.connect.flutter

import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull
import org.fountis.connect.FountisConnect
import org.fountis.connect.FountisEventListener
import org.fountis.connect.FountisResult

/** MethodChannel bridge for the FOUNTIS Connect Android SDK. */
class FountisConnectPlugin : FlutterPlugin, MethodCallHandler, ActivityAware {
  private lateinit var channel: MethodChannel
  private var context: Context? = null
  private var activity: Activity? = null
  private val tokenRequests = ConcurrentHashMap<String, CompletableDeferred<String?>>()
  private val eventListener = FountisEventListener { e ->
    val body = mutableMapOf<String, Any?>("type" to e.type)
    e.offerId?.let { body["offerId"] = it }
    channel.invokeMethod("event", body)
  }

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    channel = MethodChannel(binding.binaryMessenger, "org.fountis.connect/methods")
    channel.setMethodCallHandler(this)
    FountisConnect.onEvent(eventListener)
    // Optional: a manifest <meta-data android:name="org.fountis.connect.KEY"> starts the SDK with the engine.
    try {
      val ctx = binding.applicationContext
      val meta = ctx.packageManager.getApplicationInfo(ctx.packageName, PackageManager.GET_META_DATA).metaData
      val key = meta?.getString("org.fountis.connect.KEY")
      if (!key.isNullOrEmpty()) FountisConnect.start(ctx, key, meta?.getString("org.fountis.connect.API_BASE"))
    } catch (_: Throwable) {
    }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    context = null
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    activity = binding.activity
  }

  override fun onDetachedFromActivityForConfigChanges() {
    activity = null
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
    activity = binding.activity
  }

  override fun onDetachedFromActivity() {
    activity = null
  }

  override fun onMethodCall(call: MethodCall, result: Result) {
    when (call.method) {
      "start" -> {
        val key = call.argument<String>("key")
        val ctx = context
        if (key != null && ctx != null) FountisConnect.start(ctx, key, call.argument<String>("apiBase"))
        result.success(null)
      }

      // Dart owns the token function. The SDK asks for a token; we ask Dart and wait for resolveToken.
      "setTokenProviderEnabled" -> {
        if (call.arguments == true) {
          FountisConnect.setUserToken {
            val id = UUID.randomUUID().toString()
            val d = CompletableDeferred<String?>()
            tokenRequests[id] = d
            try {
              android.os.Handler(android.os.Looper.getMainLooper()).post { channel.invokeMethod("tokenRequest", id) }
              // Dart may not be running (a background check): give up after 10 s. No answer is a failure, not a null
              // token ("nobody is signed in"), so the SDK shows nothing instead of taking the guest path.
              val answer = withTimeoutOrNull(10_000) { TokenAnswer(d.await()) }
                ?: throw TokenUnavailableException("token provider timed out")
              answer.token
            } finally {
              tokenRequests.remove(id)
            }
          }
        }
        result.success(null)
      }

      "resolveToken" -> {
        val id = call.argument<String>("id")
        if (id != null) tokenRequests.remove(id)?.complete(call.argument<String>("token"))
        result.success(null)
      }

      // Dart's token function threw: the SDK gets an exception (nothing is shown), not a null token (a guest).
      "rejectToken" -> {
        val id = call.arguments as? String
        if (id != null) tokenRequests.remove(id)?.completeExceptionally(TokenUnavailableException("token provider failed"))
        result.success(null)
      }

      "enableNotifications" -> {
        activity?.let { FountisConnect.enableNotifications(it) }
        result.success(null)
      }

      "show" -> {
        val a = activity
        if (a == null) {
          result.success("noFill")
        } else {
          FountisConnect.show(a) { r ->
            result.success(
              when (r) {
                FountisResult.Completed -> "completed"
                FountisResult.Dismissed -> "dismissed"
                FountisResult.NoFill -> "noFill"
              },
            )
          }
        }
      }

      "handlePush" -> {
        @Suppress("UNCHECKED_CAST")
        val data = (call.arguments as? Map<String, String>) ?: emptyMap()
        result.success(FountisConnect.handlePush(data))
      }

      "setUserConsent" -> {
        FountisConnect.setUserConsent((call.arguments as? Boolean) ?: true)
        result.success(null)
      }

      "signOut" -> {
        FountisConnect.signOut()
        result.success(null)
      }

      else -> result.notImplemented()
    }
  }
}

/**
 * Thrown to the SDK when the token cannot be had (Dart's function threw, or nobody answered in time). The SDK reads a
 * throw as "could not tell who is signed in" and shows nothing; null means "nobody is signed in" and is a guest.
 * Deliberately not a CancellationException: the SDK rethrows those to the host.
 */
private class TokenUnavailableException(message: String) : Exception(message)

/** Lets a timeout (no answer) be told apart from an answer that is null. */
private class TokenAnswer(val token: String?)
