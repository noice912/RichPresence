package io.github.noice912.richpresence

import android.app.Activity
import android.content.Context
import android.os.Handler
import android.os.Looper
import com.discord.socialsdk.DiscordSocialSdkInit

/** The native side (bridge.cpp). Its callbacks arrive on the main thread, inside runCallbacks(). */
object DiscordNative {
    init {
        System.loadLibrary("discord_partner_sdk")
        System.loadLibrary("richpresence_bridge")
    }

    @JvmStatic external fun init(appId: Long)
    @JvmStatic external fun runCallbacks()
    @JvmStatic external fun authorize()
    @JvmStatic external fun useToken(access: String)
    @JvmStatic external fun refresh(refresh: String)
    @JvmStatic external fun disconnect()
    @JvmStatic external fun update(type: Int, details: String?, state: String?, start: Long, end: Long, image: String?, imageText: String?)
    @JvmStatic external fun clear()

    @JvmStatic fun onLog(msg: String) = Bus.say(msg)
    @JvmStatic fun onAuthError(msg: String) { Discord.linking = false; Bus.say(msg) }
    @JvmStatic fun onTokens(access: String, refresh: String, expiresIn: Int) = Discord.saveTokens(access, refresh, expiresIn)
    @JvmStatic fun onUser(name: String) = Discord.setUser(name)
    @JvmStatic fun onStatus(status: Int, error: String) = Discord.setStatus(status, error)
}

/** One Discord connection for the whole app, shared by the screen (linking) and the service (status). */
object Discord {
    private const val READY = 3
    private val main = Handler(Looper.getMainLooper())
    private lateinit var app: Context
    private var started = false
    private var attached = false
    @Volatile var ready = false
        private set
    var linking = false
    private var onReady: (() -> Unit)? = null

    private val pump = object : Runnable {
        override fun run() {
            DiscordNative.runCallbacks()
            main.postDelayed(this, 100)
        }
    }

    private fun prefs() = app.getSharedPreferences("discord", Context.MODE_PRIVATE)

    fun linkedName(c: Context): String? =
        c.getSharedPreferences("discord", Context.MODE_PRIVATE).getString("user", null)?.takeIf { hasTokens(c) }

    fun hasTokens(c: Context) = c.getSharedPreferences("discord", Context.MODE_PRIVATE).getString("refresh", null) != null

    /** Starts the SDK once and signs in with the saved account, if there is one. */
    /** The SDK needs one of the app's screens before it can start (it takes the app context from it). */
    fun attach(a: Activity) {
        DiscordSocialSdkInit.setEngineActivity(a)
        attached = true
    }

    fun ensure(c: Context, whenReady: (() -> Unit)? = null) {
        app = c.applicationContext
        if (whenReady != null) onReady = whenReady
        if (!attached) return
        if (!started) {
            started = true
            DiscordNative.init(BuildConfig.DISCORD_APP_ID)
            main.post(pump)
        }
        if (ready || linking) return
        val p = prefs()
        val access = p.getString("access", null)
        val refresh = p.getString("refresh", null) ?: return
        // refresh a day before the 7-day access token runs out
        if (access == null || System.currentTimeMillis() > p.getLong("expires_at", 0) - 86_400_000) DiscordNative.refresh(refresh)
        else DiscordNative.useToken(access)
    }

    fun link(a: Activity) {
        attach(a)
        ensure(a)
        linking = true
        Bus.say("Opening Discord to link your account...")
        DiscordNative.authorize()
    }

    fun unlink(c: Context) {
        c.getSharedPreferences("discord", Context.MODE_PRIVATE).edit().clear().apply()
        if (started) DiscordNative.disconnect()
        ready = false
        Bus.say("Discord account unlinked.")
    }

    fun saveTokens(access: String, refresh: String, expiresIn: Int) {
        prefs().edit().putString("access", access).putString("refresh", refresh)
            .putLong("expires_at", System.currentTimeMillis() + expiresIn * 1000L).apply()
        if (linking) Bus.say("Discord account linked.")
        linking = false
    }

    fun setUser(name: String) {
        prefs().edit().putString("user", name).apply()
        Bus.say("Signed in to Discord as $name")
    }

    fun setStatus(status: Int, error: String) {
        val was = ready
        ready = status == READY
        if (error.isNotEmpty()) Bus.say("Discord connection: $error")
        if (ready && !was) onReady?.invoke()
    }
}

/**
 * Sends the cards through the linked Discord account. The SDK allows one status per app, so a
 * game wins over music; when the game closes, the music card comes back.
 */
class SdkPresence : Presence {
    private val cards = mutableMapOf<Card.Kind, Card>()
    private var shown: String? = null

    override val ready get() = Discord.ready
    override val accountName: String? = null

    override fun start(context: Context, log: (String) -> Unit) {
        if (!Discord.hasTokens(context)) log("Link your Discord account in the app to show your status.")
        Discord.ensure(context) { shown = null; send() }
    }

    override fun show(card: Card) { cards[card.kind] = card; send() }

    override fun clear(kind: Card.Kind) { cards.remove(kind); send() }

    override fun stop() {
        cards.clear()
        if (Discord.ready) DiscordNative.clear()
        shown = null
    }

    private fun send() {
        if (!Discord.ready) return
        val c = cards[Card.Kind.GAME] ?: cards[Card.Kind.MUSIC]
        if (c == null) {
            if (shown != null) DiscordNative.clear()
            shown = null
            return
        }
        // the SDK uses the app's own name as the title, so the game/artist goes in the lines below it
        val (details, state) = when (c.kind) {
            Card.Kind.GAME -> c.name to (c.details ?: "on Android")
            Card.Kind.MUSIC -> c.details to c.state
        }
        DiscordNative.update(
            if (c.kind == Card.Kind.MUSIC) 2 else 0, details, state,
            c.startMs ?: 0, c.endMs ?: 0, c.largeImage, c.largeText,
        )
        shown = c.signature()
    }
}

object PresenceProvider {
    const val HAS_DISCORD = true
    fun create(): Presence = SdkPresence()
    fun link(a: Activity) = Discord.link(a)
    fun unlink(c: Context) = Discord.unlink(c)
    fun linkedName(c: Context) = Discord.linkedName(c)
    fun connect(a: Activity) { Discord.attach(a); Discord.ensure(a) }
}
