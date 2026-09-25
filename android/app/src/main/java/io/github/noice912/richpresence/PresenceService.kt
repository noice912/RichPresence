package io.github.noice912.richpresence

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Log lines and the status line, shared with the screen. */
object Bus {
    val lines = ArrayDeque<String>()
    @Volatile var status = "Stopped"
    var listener: (() -> Unit)? = null
    private val fmt = SimpleDateFormat("HH:mm:ss", Locale.US)
    @Synchronized fun say(m: String) {
        lines.addLast("[${fmt.format(Date())}] $m")
        while (lines.size > 300) lines.removeFirst()
        Handler(Looper.getMainLooper()).post { listener?.invoke() }
    }
}

/** Checks every few seconds what's in front and what's playing, and keeps the Discord cards in sync. */
class PresenceService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private lateinit var presence: Presence
    private val sent = mutableMapOf<Card.Kind, Pair<String, Long>>()   // signature, sent at

    companion object {
        private const val CHANNEL = "presence"
        fun start(c: Context) {
            Prefs(c).running = true
            val i = Intent(c, PresenceService::class.java)
            if (Build.VERSION.SDK_INT >= 26) c.startForegroundService(i) else c.startService(i)
        }
        fun stop(c: Context) {
            Prefs(c).running = false
            c.stopService(Intent(c, PresenceService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) nm.createNotificationChannel(NotificationChannel(CHANNEL, "Presence running", NotificationManager.IMPORTANCE_LOW))
        val n = notification("Starting...")
        if (Build.VERSION.SDK_INT >= 34) startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE) else startForeground(1, n)
        presence = PresenceProvider.create()
        presence.start(this, Bus::say)
        Bus.say("Presence started.")
        handler.post(tick)
    }

    private fun notification(text: String): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else @Suppress("DEPRECATION") Notification.Builder(this)
        return b.setSmallIcon(android.R.drawable.stat_notify_sync_noanim).setContentTitle("RichPresence")
            .setContentText(text).setContentIntent(open).setOngoing(true).build()
    }

    private fun push(card: Card?, kind: Card.Kind) {
        val now = System.currentTimeMillis()
        val last = sent[kind]
        if (card == null) {
            if (last != null) { presence.clear(kind); sent.remove(kind) }
            return
        }
        val sig = card.signature()
        val changed = last?.first != sig
        if (changed || now - last!!.second > 30_000) {
            presence.show(card)
            sent[kind] = sig to now
            if (changed) Bus.say(if (kind == Card.Kind.GAME) "Playing: ${card.name}" else "Music: ${card.name} - ${card.details}")
        }
    }

    private val tick = object : Runnable {
        override fun run() {
            try {
                val p = Prefs(this@PresenceService)
                val game = if (p.showGames) Detect.currentGame(this@PresenceService) else null
                val track = if (p.showMusic) Detect.nowPlaying(this@PresenceService, p.musicOnly) else null
                push(game?.let(Cards::game), Card.Kind.GAME)
                push(track?.let { Cards.music(it, System.currentTimeMillis()) }, Card.Kind.MUSIC)
                val parts = listOfNotNull(game?.let { "Playing ${it.label}" }, track?.let { "Listening: ${it.title}" })
                val status = parts.joinToString("  |  ").ifEmpty { "Watching for games and music" }
                if (status != Bus.status) {
                    Bus.status = status
                    getSystemService(NotificationManager::class.java).notify(1, notification(status))
                }
            } catch (e: Exception) {
                Bus.say("Error: ${e.message}")
            }
            handler.postDelayed(this, 5_000)
        }
    }

    override fun onDestroy() {
        handler.removeCallbacks(tick)
        Card.Kind.entries.forEach { if (sent.containsKey(it)) presence.clear(it) }
        presence.stop()
        Bus.status = "Stopped"
        Bus.say("Presence stopped.")
        super.onDestroy()
    }
}
