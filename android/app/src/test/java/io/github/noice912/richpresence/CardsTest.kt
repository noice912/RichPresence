package io.github.noice912.richpresence

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CardsTest {
    private val t = Track("Spotify", "Quack Song", "The Ducks", "Pond", "https://i.scdn.co/a.jpg", 200_000, 50_000, 1_000_000)

    @Test fun musicCardShowsTitleArtistAndProgress() {
        val c = Cards.music(t, nowMs = 1_010_000)       // 10 s after the position was read
        assertEquals(Card.Kind.MUSIC, c.kind)
        assertEquals("The Ducks", c.name)
        assertEquals("Quack Song", c.details)
        assertEquals("by The Ducks", c.state)
        assertEquals(1_010_000L - 60_000, c.startMs)     // 50 s + 10 s into the song
        assertEquals(c.startMs!! + 200_000, c.endMs)
        assertEquals("https://i.scdn.co/a.jpg", c.largeImage)
        assertEquals("Quack Song - Pond", c.largeText)
    }

    @Test fun lyricReplacesTheArtistLine() {
        assertEquals("quack quack", Cards.music(t, 1_000_000, "quack quack").state)
    }

    @Test fun positionNeverRunsPastTheEnd() {
        val c = Cards.music(t, nowMs = 9_000_000)
        assertEquals(c.startMs!! + 200_000, c.endMs)
        assertEquals(9_000_000L - 200_000, c.startMs)
    }

    @Test fun nonHttpsArtIsDropped() {
        assertNull(Cards.music(t.copy(artUrl = "content://media/1"), 1_000_000).largeImage)
    }

    @Test fun noArtistFallsBackToThePlayer() {
        val c = Cards.music(t.copy(artist = ""), 1_000_000)
        assertEquals("Spotify", c.name)
        assertEquals("Spotify", c.state)
    }

    @Test fun longTextIsClipped() {
        val c = Cards.music(t.copy(title = "x".repeat(300)), 1_000_000)
        assertEquals(128, c.details!!.length)
        assertTrue(c.details!!.endsWith("..."))
    }

    @Test fun gameCard() {
        val c = Cards.game(Game("com.mihoyo.genshinimpact", "Genshin Impact", 123L))
        assertEquals("Genshin Impact", c.name)
        assertEquals(123L, c.startMs)
    }

    @Test fun signatureIgnoresTheMovingProgressBar() {
        assertEquals(Cards.music(t, 1_000_000).signature(), Cards.music(t, 1_005_000).signature())
        assertNotEquals(Cards.music(t, 1_000_000).signature(), Cards.music(t.copy(title = "Other"), 1_000_000).signature())
    }

    @Test fun videoAppsAreNotMusicPlayers() {
        assertFalse(Cards.isMusicPlayer("com.google.android.youtube"))
        assertTrue(Cards.isMusicPlayer("com.spotify.music"))
        assertTrue(Cards.isMusicPlayer("com.apple.android.music"))
    }
}
