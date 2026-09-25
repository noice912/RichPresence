package io.github.noice912.richpresence

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.CheckBox
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

/** One scrolling screen: permissions, start/stop, options, your games, and the log. */
class MainActivity : Activity() {
    private val bg = Color.parseColor("#14161b")
    private val card = Color.parseColor("#1f232b")
    private val fg = Color.parseColor("#e8eaf0")
    private val dim = Color.parseColor("#8b91a1")
    private val accent = Color.parseColor("#5865f2")
    private val green = Color.parseColor("#3ba55d")

    private lateinit var root: LinearLayout
    private lateinit var status: TextView
    private lateinit var toggle: Button
    private lateinit var permBox: LinearLayout
    private lateinit var gamesBox: LinearLayout
    private lateinit var log: TextView
    private val prefs by lazy { Prefs(this) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.statusBarColor = bg
        root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(18), dp(18), dp(18), dp(18)) }
        setContentView(ScrollView(this).apply { setBackgroundColor(bg); addView(root) })

        label("RichPresence", 26f, fg, bold = true)
        label("Shows the game or song you're playing on your Discord status.", 14f, dim)

        section("Discord")
        label("Linking your Discord account arrives with the next update. Until then the app shows here what it would put on your status.", 13f, dim)

        section("Permissions")
        permBox = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(permBox)

        section("Presence")
        status = label("", 14f, dim)
        toggle = button("Start") { if (prefs.running) PresenceService.stop(this) else start(); refresh() }

        section("Show")
        check("The game I'm playing", prefs.showGames) { prefs.showGames = it }
        check("What I'm listening to", prefs.showMusic) { prefs.showMusic = it }
        check("Only music apps (skip YouTube, browsers and video)", prefs.musicOnly) { prefs.musicOnly = it }

        section("My games")
        label("Apps that tell Android they're games. Untick one to keep it private, or add any app that's missing.", 13f, dim)
        gamesBox = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(gamesBox)
        button("+ Add an app as a game", primary = false) { pickApp() }

        section("Log")
        log = label("", 11f, dim).apply { typeface = Typeface.MONOSPACE }
    }

    override fun onResume() {
        super.onResume()
        Bus.listener = { refresh() }
        refresh()
        fillGames()
    }

    override fun onPause() {
        Bus.listener = null
        super.onPause()
    }

    private fun start() {
        if (Build.VERSION.SDK_INT >= 33) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        PresenceService.start(this)
    }

    private fun refresh() {
        permBox.removeAllViews()
        permRow("Usage access", "to see which game is open", Detect.hasUsageAccess(this), Settings.ACTION_USAGE_ACCESS_SETTINGS)
        permRow("Notification access", "to read what's playing (song, artist). Notifications themselves aren't read.",
            Detect.hasNotificationAccess(this), Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
        toggle.text = if (prefs.running) "Stop" else "Start"
        status.text = if (prefs.running) "On  -  ${Bus.status}" else "Off"
        status.setTextColor(if (prefs.running) green else dim)
        log.text = synchronized(Bus) { Bus.lines.toList().takeLast(60).joinToString("\n") }
    }

    private fun permRow(name: String, why: String, granted: Boolean, action: String) {
        val row = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(0, dp(4), 0, dp(4)) }
        permBox.addView(row)
        row.addView(TextView(this).apply { this.text = (if (granted) "✓  " else "✗  ") + name; setTextColor(if (granted) green else fg); textSize = 15f })
        row.addView(TextView(this).apply { this.text = why; setTextColor(dim); textSize = 12f })
        if (!granted) row.addView(Button(this).apply {
            this.text = "Allow in Settings"; setOnClickListener { startActivity(Intent(action)) }
        })
    }

    private fun fillGames() {
        gamesBox.removeAllViews()
        val games = Detect.installedGames(this)
        if (games.isEmpty()) label("No games found yet.", 13f, dim, into = gamesBox)
        for ((pkg, name) in games) {
            val cb = CheckBox(this).apply {
                this.text = name; setTextColor(fg); isChecked = pkg !in prefs.disabledGames
                setOnCheckedChangeListener { _, on -> prefs.disabledGames = if (on) prefs.disabledGames - pkg else prefs.disabledGames + pkg }
            }
            gamesBox.addView(cb)
        }
    }

    private fun pickApp() {
        val apps = Detect.launchableApps(this)
        AlertDialog.Builder(this).setTitle("Add an app as a game")
            .setItems(apps.map { it.second }.toTypedArray()) { _, i ->
                prefs.addedGames = prefs.addedGames + apps[i].first
                fillGames()
            }.show()
    }

    // ------------------------------------------------ tiny view helpers
    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    private fun label(s: String, size: Float, color: Int, bold: Boolean = false, into: LinearLayout = root) =
        TextView(this).apply {
            text = s; textSize = size; setTextColor(color)
            if (bold) typeface = Typeface.DEFAULT_BOLD
            setPadding(0, dp(2), 0, dp(2))
            into.addView(this)
        }

    private fun section(s: String) {
        root.addView(View(this).apply { setBackgroundColor(card) }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(1)).apply { topMargin = dp(16); bottomMargin = dp(8) })
        label(s, 17f, fg, bold = true)
    }

    private fun button(s: String, primary: Boolean = true, onClick: () -> Unit) = Button(this).apply {
        text = s; setTextColor(Color.WHITE); gravity = Gravity.CENTER
        setBackgroundColor(if (primary) accent else card)
        setOnClickListener { onClick() }
        root.addView(this, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(6) })
    }

    private fun check(s: String, initial: Boolean, onChange: (Boolean) -> Unit) = CheckBox(this).apply {
        text = s; setTextColor(fg); isChecked = initial
        setOnCheckedChangeListener { _, on -> onChange(on) }
        root.addView(this)
    }
}
