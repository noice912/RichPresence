package io.github.noice912.richpresence

/** What one Discord card should show. Kept free of Android classes so it can be unit-tested. */
data class Card(
    val kind: Kind,
    val name: String,
    val details: String? = null,
    val state: String? = null,
    val startMs: Long? = null,
    val endMs: Long? = null,
    val largeImage: String? = null,
    val largeText: String? = null,
) {
    enum class Kind { GAME, MUSIC }

    /** Changes that should be sent right away (as opposed to a periodic refresh). */
    fun signature() = listOf(kind, name, details, state, largeImage).joinToString("|")
}

data class Game(val packageName: String, val label: String, val sinceMs: Long)

data class Track(
    val player: String,
    val title: String,
    val artist: String,
    val album: String,
    val artUrl: String?,
    val durationMs: Long,
    val positionMs: Long,
    val positionAtMs: Long,
)

object Cards {
    private fun clip(s: String?, n: Int = 128): String? =
        s?.trim()?.takeIf { it.isNotEmpty() }?.let { if (it.length <= n) it else it.take(n - 3) + "..." }

    fun game(g: Game): Card = Card(
        kind = Card.Kind.GAME,
        name = clip(g.label)!!,
        details = "on Android",
        startMs = g.sinceMs,
    )

    /** "Listening to <artist>": title on the first line, artist (or lyric) on the second, with a progress bar. */
    fun music(t: Track, nowMs: Long, lyricLine: String? = null): Card {
        val pos = (t.positionMs + (nowMs - t.positionAtMs)).coerceAtLeast(0)
            .let { if (t.durationMs > 0) it.coerceAtMost(t.durationMs) else it }
        val start = nowMs - pos
        return Card(
            kind = Card.Kind.MUSIC,
            name = clip(t.artist.ifBlank { t.player }) ?: "Music",
            details = clip(t.title),
            state = clip(lyricLine) ?: clip(if (t.artist.isNotBlank()) "by ${t.artist}" else t.player),
            startMs = start,
            endMs = if (t.durationMs > 0) start + t.durationMs else null,
            largeImage = t.artUrl?.takeIf { it.startsWith("https://") },
            largeText = clip(if (t.album.isNotBlank()) "${t.title} - ${t.album}" else t.title),
        )
    }

    /** Players that are usually video or browsers, skipped when "music apps only" is on. */
    private val notMusic = listOf("youtube", "chrome", "firefox", "browser", "netflix", "vlc", "mxtech", "twitch", "disney", "primevideo")
    fun isMusicPlayer(pkg: String) = notMusic.none { pkg.lowercase().contains(it) }
}
