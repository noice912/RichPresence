package io.github.noice912.richpresence

import android.app.Activity
import android.content.Context

/** Used when the build doesn't include Discord's Social SDK (e.g. the public CI build). */
object PresenceProvider {
    const val HAS_DISCORD = false
    fun create(): Presence = LogOnlyPresence()
    fun link(a: Activity) {}
    fun unlink(c: Context) {}
    fun linkedName(c: Context): String? = null
    fun connect(a: Activity) {}
}
