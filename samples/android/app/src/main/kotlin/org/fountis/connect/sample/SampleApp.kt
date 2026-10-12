package org.fountis.connect.sample

import android.app.Application
import android.util.Base64
import java.util.UUID
import org.fountis.connect.FountisConnect
import org.json.JSONObject

class SampleApp : Application() {
    override fun onCreate() {
        super.onCreate()
        // At launch, from Application.onCreate: this also lets the background check work when the system starts the process.
        FountisConnect.start(this, BuildConfig.SANDBOX_KEY, BuildConfig.API_BASE)
        FountisConnect.setUserToken { SampleSession.token() }
    }
}

/**
 * Stands in for the partner's own sign-in. A real app asks its server for a signed token
 * (see samples/server-node); this sandbox sample makes an unsigned one for a fake user.
 */
object SampleSession {
    @Volatile var signedIn = true

    private const val PARTNER_ID = "ptn_demo"
    private const val APP_ID = "app_demo_android"

    fun token(): String? {
        if (!signedIn) return null
        fun b64(o: JSONObject) =
            Base64.encodeToString(o.toString().toByteArray(), Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
        val iat = System.currentTimeMillis() / 1000
        val attrs = JSONObject()
            .put("gender", "female").put("birth_year", 1992).put("governorate", "erbil").put("city", "erbil").put("lang", "en")
        val payload = JSONObject()
            .put("iss", PARTNER_ID).put("aud", "fountis-connect:$APP_ID")
            .put("sub", "sandbox_user_0001_AAAAAAAAAAAAAAAA").put("kyc", "verified")
            .put("attrs", attrs).put("mapping_version", 1)
            .put("iat", iat).put("exp", iat + 3600).put("jti", UUID.randomUUID().toString())
        return b64(JSONObject().put("alg", "none").put("typ", "JWT")) + "." + b64(payload) + "."
    }
}
