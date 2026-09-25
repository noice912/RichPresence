package io.github.noice912.richpresence

import android.app.AppOpsManager
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.ComponentName
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.media.MediaMetadata
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Build
import android.os.Process
import android.provider.Settings

/** Reads which game is in front (usage access) and what is playing (notification access). */
object Detect {

    // ------------------------------------------------ permissions
    fun hasUsageAccess(c: Context): Boolean {
        val ops = c.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = if (Build.VERSION.SDK_INT >= 29)
            ops.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), c.packageName)
        else @Suppress("DEPRECATION") ops.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), c.packageName)
        return mode == AppOpsManager.MODE_ALLOWED
    }

    fun hasNotificationAccess(c: Context): Boolean {
        val flat = Settings.Secure.getString(c.contentResolver, "enabled_notification_listeners") ?: return false
        return flat.split(':').any { ComponentName.unflattenFromString(it)?.packageName == c.packageName }
    }

    // ------------------------------------------------ games
    @Suppress("DEPRECATION")
    fun isGame(info: ApplicationInfo): Boolean =
        (Build.VERSION.SDK_INT >= 26 && info.category == ApplicationInfo.CATEGORY_GAME) ||
            (info.flags and ApplicationInfo.FLAG_IS_GAME) != 0

    /** Installed apps that say they're games, plus any the person added by hand. */
    fun installedGames(c: Context): List<Pair<String, String>> {
        val pm = c.packageManager
        val added = Prefs(c).addedGames
        return pm.getInstalledApplications(PackageManager.GET_META_DATA)
            .filter { pm.getLaunchIntentForPackage(it.packageName) != null && (isGame(it) || it.packageName in added) }
            .map { it.packageName to pm.getApplicationLabel(it).toString() }
            .sortedBy { it.second.lowercase() }
    }

    fun launchableApps(c: Context): List<Pair<String, String>> {
        val pm = c.packageManager
        return pm.getInstalledApplications(0)
            .filter { pm.getLaunchIntentForPackage(it.packageName) != null && it.packageName != c.packageName }
            .map { it.packageName to pm.getApplicationLabel(it).toString() }
            .sortedBy { it.second.lowercase() }
    }

    private var lastFront: String? = null
    private var lastFrontSince = 0L

    /** The app in front right now, from the last few minutes of usage events. */
    fun foregroundPackage(c: Context): Pair<String, Long>? {
        val usm = c.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val now = System.currentTimeMillis()
        val events = usm.queryEvents(now - 10 * 60_000, now)
        val e = UsageEvents.Event()
        var front: String? = null
        var since = 0L
        while (events.hasNextEvent()) {
            events.getNextEvent(e)
            val resumed = if (Build.VERSION.SDK_INT >= 29) UsageEvents.Event.ACTIVITY_RESUMED else @Suppress("DEPRECATION") UsageEvents.Event.MOVE_TO_FOREGROUND
            val paused = if (Build.VERSION.SDK_INT >= 29) UsageEvents.Event.ACTIVITY_PAUSED else @Suppress("DEPRECATION") UsageEvents.Event.MOVE_TO_BACKGROUND
            when (e.eventType) {
                resumed -> { if (front != e.packageName) since = e.timeStamp; front = e.packageName }
                paused -> if (front == e.packageName) front = null
            }
        }
        if (front == null && lastFront != null && usm.isAppInactive(lastFront!!).not()) {
            // no events in the window: the same app has simply stayed in front
            front = lastFront; since = lastFrontSince
        }
        if (front != lastFront) { lastFront = front; lastFrontSince = since }
        return front?.let { it to (if (lastFrontSince > 0) lastFrontSince else now) }
    }

    fun currentGame(c: Context): Game? {
        if (!hasUsageAccess(c)) return null
        val (pkg, since) = foregroundPackage(c) ?: return null
        val prefs = Prefs(c)
        if (pkg in prefs.disabledGames) return null
        val pm = c.packageManager
        val info = try { pm.getApplicationInfo(pkg, 0) } catch (_: PackageManager.NameNotFoundException) { return null }
        if (!isGame(info) && pkg !in prefs.addedGames) return null
        return Game(pkg, pm.getApplicationLabel(info).toString(), since)
    }

    // ------------------------------------------------ music
    fun nowPlaying(c: Context, musicOnly: Boolean): Track? {
        if (!hasNotificationAccess(c)) return null
        val msm = c.getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager
        val sessions = try {
            msm.getActiveSessions(ComponentName(c, MediaListener::class.java))
        } catch (_: SecurityException) { return null }
        val pm = c.packageManager
        for (s in sessions) {
            val st = s.playbackState ?: continue
            if (st.state != PlaybackState.STATE_PLAYING) continue
            if (musicOnly && !Cards.isMusicPlayer(s.packageName)) continue
            val md = s.metadata ?: continue
            val title = md.getString(MediaMetadata.METADATA_KEY_TITLE)?.trim().orEmpty()
            if (title.isEmpty()) continue
            val label = try { pm.getApplicationLabel(pm.getApplicationInfo(s.packageName, 0)).toString() } catch (_: Exception) { s.packageName }
            return Track(
                player = label,
                title = title,
                artist = (md.getString(MediaMetadata.METADATA_KEY_ARTIST) ?: md.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST)).orEmpty().trim(),
                album = md.getString(MediaMetadata.METADATA_KEY_ALBUM).orEmpty().trim(),
                artUrl = listOf(MediaMetadata.METADATA_KEY_ART_URI, MediaMetadata.METADATA_KEY_ALBUM_ART_URI, MediaMetadata.METADATA_KEY_DISPLAY_ICON_URI)
                    .firstNotNullOfOrNull { k -> md.getString(k)?.takeIf { it.startsWith("https://") } },
                durationMs = md.getLong(MediaMetadata.METADATA_KEY_DURATION),
                positionMs = st.position,
                positionAtMs = System.currentTimeMillis() - (android.os.SystemClock.elapsedRealtime() - st.lastPositionUpdateTime).coerceAtLeast(0),
            )
        }
        return null
    }
}
