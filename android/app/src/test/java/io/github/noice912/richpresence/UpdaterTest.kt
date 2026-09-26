package io.github.noice912.richpresence

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UpdaterTest {
    @Test fun newerVersionsAreNewer() {
        assertTrue(Updater.isNewer("1.2.1", "1.2.0"))
        assertTrue(Updater.isNewer("v1.10.0", "1.9.9"))   // numbers, not text
        assertTrue(Updater.isNewer("2.0", "1.99.99"))
    }

    @Test fun sameOrOlderIsNotNewer() {
        assertFalse(Updater.isNewer("1.2.0", "1.2.0"))
        assertFalse(Updater.isNewer("1.2", "1.2.0"))
        assertFalse(Updater.isNewer("1.1.9", "1.2.0"))
    }

    @Test fun oddVersionsDontCrash() {
        assertEquals(listOf(1, 2, 0), Updater.versionParts("v1.2-beta"))
        assertEquals(listOf(0, 0, 0), Updater.versionParts(""))
    }
}
