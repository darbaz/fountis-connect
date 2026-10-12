package org.fountis.connect.sample

import android.app.Activity
import android.content.Intent
import android.graphics.Typeface
import android.os.Bundle
import android.view.Gravity
import android.view.ViewGroup
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import org.fountis.connect.FountisConnect

class MainActivity : Activity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private lateinit var log: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val dp = resources.displayMetrics.density
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding((20 * dp).toInt(), (20 * dp).toInt(), (20 * dp).toInt(), (20 * dp).toInt()) }
        ViewCompat.setOnApplyWindowInsetsListener(root) { v, insets ->
            val b = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            val pad = (20 * dp).toInt()
            v.setPadding(pad + b.left, pad + b.top, pad + b.right, pad + b.bottom)
            WindowInsetsCompat.CONSUMED
        }
        root.addView(TextView(this).apply { text = "Acme Phone"; textSize = 30f; setTypeface(typeface, Typeface.BOLD) })
        root.addView(TextView(this).apply { text = "A made-up partner app. Fake user: a woman born 1992 in Erbil."; setPadding(0, (8 * dp).toInt(), 0, (16 * dp).toInt()) })

        val buttons = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.START }
        val show = Button(this).apply { text = "Show study" }
        val sign = Button(this).apply { text = "Sign out" }
        buttons.addView(show)
        buttons.addView(sign)
        root.addView(buttons)

        log = TextView(this).apply { typeface = Typeface.MONOSPACE; textSize = 12f; text = "events appear here"; setPadding(0, (12 * dp).toInt(), 0, 0) }
        root.addView(ScrollView(this).apply { addView(log) }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        setContentView(root)

        FountisConnect.onEvent { e -> add("${e.type} ${e.offerId ?: ""}") }
        FountisConnect.enableNotifications(this)

        show.setOnClickListener {
            scope.launch { add("show() -> ${FountisConnect.show(this@MainActivity)}") }
        }
        sign.setOnClickListener {
            SampleSession.signedIn = !SampleSession.signedIn
            if (!SampleSession.signedIn) FountisConnect.signOut()
            sign.text = if (SampleSession.signedIn) "Sign out" else "Sign in"
            add(if (SampleSession.signedIn) "signed in" else "signed out")
        }
    }

    // singleTop launcher: a tapped notification arrives here when the app is already open.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        FountisConnect.handleIntent(intent)
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    private fun add(s: String) {
        log.text = s + "\n" + log.text
    }
}
