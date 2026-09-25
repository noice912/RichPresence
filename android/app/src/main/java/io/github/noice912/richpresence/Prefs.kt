package io.github.noice912.richpresence

import android.content.Context

class Prefs(c: Context) {
    private val p = c.getSharedPreferences("richpresence", Context.MODE_PRIVATE)

    var showGames: Boolean
        get() = p.getBoolean("show_games", true)
        set(v) = p.edit().putBoolean("show_games", v).apply()
    var showMusic: Boolean
        get() = p.getBoolean("show_music", true)
        set(v) = p.edit().putBoolean("show_music", v).apply()
    var musicOnly: Boolean
        get() = p.getBoolean("music_only", true)
        set(v) = p.edit().putBoolean("music_only", v).apply()
    var running: Boolean
        get() = p.getBoolean("running", false)
        set(v) = p.edit().putBoolean("running", v).apply()
    var disabledGames: Set<String>
        get() = p.getStringSet("disabled_games", emptySet())!!.toSet()
        set(v) = p.edit().putStringSet("disabled_games", v).apply()
    var addedGames: Set<String>
        get() = p.getStringSet("added_games", emptySet())!!.toSet()
        set(v) = p.edit().putStringSet("added_games", v).apply()
}
