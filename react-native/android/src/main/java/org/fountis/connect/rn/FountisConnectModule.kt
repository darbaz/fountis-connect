package org.fountis.connect.rn

import expo.modules.kotlin.Promise
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull
import org.fountis.connect.FountisConnect
import org.fountis.connect.FountisEvent
import org.fountis.connect.FountisEventListener
import org.fountis.connect.FountisResult

/** JS bridge for the FOUNTIS Connect Android SDK. */
class FountisConnectModule : Module() {
  private val tokenRequests = ConcurrentHashMap<String, CompletableDeferred<String?>>()
  private val eventListener = FountisEventListener { e: FountisEvent ->
    val body = mutableMapOf<String, Any?>("type" to e.type)
    e.offerId?.let { body["offerId"] = it }
    sendEvent("onFountisEvent", body)
  }

  override fun definition() = ModuleDefinition {
    Name("FountisConnect")

    Events("onFountisEvent", "onTokenRequest")

    OnCreate {
      FountisConnect.onEvent(eventListener)
      // Optional: the config plugin can write the key into the manifest so the SDK starts with the app.
      val ctx = appContext.reactContext ?: return@OnCreate
      try {
        val meta = ctx.packageManager
          .getApplicationInfo(ctx.packageName, android.content.pm.PackageManager.GET_META_DATA).metaData
        val key = meta?.getString("org.fountis.connect.KEY")
        if (!key.isNullOrEmpty()) FountisConnect.start(ctx, key, meta?.getString("org.fountis.connect.API_BASE"))
      } catch (_: Throwable) {
      }
    }

    Function("start") { key: String, apiBase: String? ->
      appContext.reactContext?.let { FountisConnect.start(it, key, apiBase) }
      Unit
    }

    // JS owns the token function. The SDK asks for a token; we ask JS with an event and wait for resolveToken.
    Function("setTokenProviderEnabled") { enabled: Boolean ->
      if (enabled) {
        FountisConnect.setUserToken {
          val id = UUID.randomUUID().toString()
          val d = CompletableDeferred<String?>()
          tokenRequests[id] = d
          try {
            sendEvent("onTokenRequest", mapOf("id" to id))
            // JS may not be running (a background check): give up after 10 s. That is a failure, not "signed out":
            // an answer of null (nobody signed in) is wrapped so it cannot be mistaken for the timeout.
            val answer = withTimeoutOrNull(10_000) { TokenAnswer(d.await()) }
              ?: throw TokenUnavailableException("token provider timed out")
            answer.token
          } finally {
            tokenRequests.remove(id)
          }
        }
      }
    }

    Function("resolveToken") { id: String, token: String? ->
      tokenRequests.remove(id)?.complete(token)
      Unit
    }

    // The JS token function threw or rejected: the SDK gets an exception (noFill), not null (nobody is signed in).
    Function("rejectToken") { id: String ->
      tokenRequests.remove(id)?.completeExceptionally(TokenUnavailableException("token provider failed"))
      Unit
    }

    Function("enableNotifications") {
      appContext.currentActivity?.let { FountisConnect.enableNotifications(it) }
      Unit
    }

    Function("setUserConsent") { granted: Boolean -> FountisConnect.setUserConsent(granted) }

    Function("signOut") { FountisConnect.signOut() }

    AsyncFunction("show") { promise: Promise ->
      val activity = appContext.currentActivity
      if (activity == null) {
        promise.resolve("noFill")
      } else {
        FountisConnect.show(activity) { r: FountisResult ->
          promise.resolve(
            when (r) {
              FountisResult.Completed -> "completed"
              FountisResult.Dismissed -> "dismissed"
              FountisResult.NoFill -> "noFill"
            },
          )
        }
      }
    }

    AsyncFunction("handlePush") { data: Map<String, String> -> FountisConnect.handlePush(data) }
  }
}

/** Holds the token (null = nobody signed in) so a real answer of null differs from the timeout, which is also null. */
private class TokenAnswer(val token: String?)

/** The token could not be fetched. Not a CancellationException: the SDK rethrows those to the host app. */
private class TokenUnavailableException(message: String) : Exception(message)
