package io.github.noice912.richpresence

import android.service.notification.NotificationListenerService

/**
 * Only exists so Android lets us read other players' media sessions (song, artist, position).
 * No notification content is read or stored.
 */
class MediaListener : NotificationListenerService()
