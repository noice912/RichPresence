package io.github.noice912.richpresence

import android.content.Context

/**
 * Sends cards to Discord. The real implementation uses Discord's Social SDK with the person's
 * linked Discord account; until the SDK is added to the build, [LogOnlyPresence] just records
 * what would be shown, so everything else can be used and tested.
 */
interface Presence {
    val ready: Boolean
    val accountName: String?
    fun start(context: Context, log: (String) -> Unit)
    fun show(card: Card)
    fun clear(kind: Card.Kind)
    fun stop()
}

class LogOnlyPresence : Presence {
    private var log: (String) -> Unit = {}
    override val ready = false
    override val accountName: String? = null
    override fun start(context: Context, log: (String) -> Unit) {
        this.log = log
        log("Discord isn't linked yet: the Social SDK still has to be added to this build. Showing what would be sent.")
    }
    override fun show(card: Card) = log("Would show: ${card.name}${card.details?.let { " - $it" } ?: ""}")
    override fun clear(kind: Card.Kind) = log("Would clear the ${kind.name.lowercase()} card")
    override fun stop() {}
}

object PresenceProvider {
    /** Swapped for the Social SDK implementation once it is part of the build. */
    fun create(): Presence = LogOnlyPresence()
}
