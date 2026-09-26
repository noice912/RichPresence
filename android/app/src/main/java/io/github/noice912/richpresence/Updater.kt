package io.github.noice912.richpresence

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/**
 * Updates from GitHub releases. Android always asks the person to confirm an install, so this
 * downloads the new APK, checks it against the SHA-256 GitHub publishes, and opens the installer.
 */
object Updater {
    private const val API = "https://api.github.com/repos/noice912/RichPresence/releases/latest"
    private const val ASSET = "RichPresence-android.apk"

    sealed class Result {
        object Current : Result()
        data class Ready(val version: String, val file: File) : Result()
        data class Failed(val why: String) : Result()
    }

    fun versionParts(v: String): List<Int> =
        v.trim().removePrefix("v").split('.').map { p -> p.takeWhile { it.isDigit() }.toIntOrNull() ?: 0 }
            .let { it + List((3 - it.size).coerceAtLeast(0)) { 0 } }

    fun isNewer(latest: String, current: String): Boolean {
        val a = versionParts(latest)
        val b = versionParts(current)
        for (i in 0 until maxOf(a.size, b.size)) {
            val x = a.getOrElse(i) { 0 }
            val y = b.getOrElse(i) { 0 }
            if (x != y) return x > y
        }
        return false
    }

    /** Runs on a background thread. */
    fun check(dir: File, current: String): Result = try {
        val rel = JSONObject(get(API).readBytes().toString(Charsets.UTF_8))
        val latest = rel.optString("tag_name").removePrefix("v")
        if (!isNewer(latest, current)) Result.Current
        else {
            val assets = rel.optJSONArray("assets")
            val asset = (0 until (assets?.length() ?: 0)).map { assets!!.getJSONObject(it) }.firstOrNull { it.optString("name") == ASSET }
            val want = asset?.optString("digest").orEmpty().removePrefix("sha256:").lowercase()
            if (asset == null || want.isEmpty()) Result.Failed("Update $latest has no APK with a published checksum")
            else {
                dir.mkdirs()
                dir.listFiles()?.forEach { it.delete() }
                val file = File(dir, "RichPresence-$latest.apk")
                val md = MessageDigest.getInstance("SHA-256")
                get(asset.getString("browser_download_url")).use { input ->
                    file.outputStream().use { out ->
                        val buf = ByteArray(1 shl 16)
                        while (true) {
                            val n = input.read(buf)
                            if (n < 0) break
                            md.update(buf, 0, n)
                            out.write(buf, 0, n)
                        }
                    }
                }
                val got = md.digest().joinToString("") { "%02x".format(it) }
                if (got != want) { file.delete(); Result.Failed("Update $latest didn't match its checksum and was deleted") }
                else Result.Ready(latest, file)
            }
        }
    } catch (e: Exception) {
        Result.Failed("Couldn't check for updates: ${e.message}")
    }

    private fun get(url: String) = (URL(url).openConnection() as HttpURLConnection).run {
        instanceFollowRedirects = true
        connectTimeout = 20_000
        readTimeout = 120_000
        setRequestProperty("User-Agent", "RichPresence updater")
        inputStream
    }

    /** Opens Android's installer for the downloaded APK (asking for the one-time permission first if needed). */
    fun install(a: Activity, file: File) {
        if (Build.VERSION.SDK_INT >= 26 && !a.packageManager.canRequestPackageInstalls()) {
            a.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${a.packageName}")))
            return
        }
        val uri = FileProvider.getUriForFile(a, "${a.packageName}.files", file)
        a.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
