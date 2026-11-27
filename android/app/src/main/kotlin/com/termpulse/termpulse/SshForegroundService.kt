package com.termpulse.termpulse

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

class SshForegroundService : Service() {
    companion object {
        const val CHANNEL_ID = "termpulse_sessions"
        const val NOTIFICATION_ID = 4201
        const val EXTRA_SESSION_COUNT = "session_count"
        const val ACTION_STOP = "com.termpulse.termpulse.STOP_FOREGROUND"
        // The activity owns this callback and clears it when its engine detaches.
        // A stopped service must never claim that it disconnected SSH sessions.
        var onStopped: ((String) -> Unit)? = null
        private val defaultStrings = mapOf(
            "notification_title" to "TermPulse đang hỗ trợ chạy nền",
            "notification_text" to "1 phiên đang hoạt động nền",
            "notification_stop" to "Tắt dịch vụ nền",
            "channel_name" to "Phiên kết nối chạy nền",
            "channel_description" to "Hỗ trợ phiên kết nối khi chuyển ứng dụng; Android có thể giới hạn thời gian chạy nền."
        )

        fun startOrUpdate(context: Context, count: Int, strings: Map<String, String>) {
            val intent = Intent(context, SshForegroundService::class.java).apply {
                putExtra(EXTRA_SESSION_COUNT, count)
                strings.forEach { (key, value) ->
                    if (key in defaultStrings) putExtra(key, value)
                }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, SshForegroundService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            finishService("user")
            return START_NOT_STICKY
        }

        // A recreated service has no authoritative session count: do not show
        // an ongoing-session notification until Flutter reports actual sessions.
        if (intent == null || intent.getIntExtra(EXTRA_SESSION_COUNT, 0) <= 0) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }

        // Retain the last app-selected language when the service is updated.
        val preferences = getSharedPreferences("foreground_notification", MODE_PRIVATE)
        val count = intent.getIntExtra(EXTRA_SESSION_COUNT, 0)
        val strings = defaultStrings.mapValues { (key, fallback) ->
            intent.getStringExtra(key) ?: preferences.getString(key, fallback) ?: fallback
        }
        preferences.edit().apply {
            putInt(EXTRA_SESSION_COUNT, count)
            strings.forEach { (key, value) -> putString(key, value) }
            apply()
        }
        ensureChannel(strings.getValue("channel_name"), strings.getValue("channel_description"))

        val openAppIntent = Intent(this, MainActivity::class.java).apply {
            this.flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val openPending = PendingIntent.getActivity(
            this,
            0,
            openAppIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val stopIntent = Intent(this, SshForegroundService::class.java).apply {
            action = ACTION_STOP
        }
        val stopPending = PendingIntent.getService(
            this,
            1,
            stopIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        val notification = builder
            .setContentTitle(strings.getValue("notification_title"))
            .setContentText(strings.getValue("notification_text"))
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentIntent(openPending)
            .setOngoing(true)
            .addAction(
                Notification.Action.Builder(
                    null,
                    strings.getValue("notification_stop"),
                    stopPending
                ).build()
            )
            .build()

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (error: RuntimeException) {
            // The OS can reject promotion after startForegroundService returns,
            // for example once the Android 15 dataSync budget has expired.
            finishService("start_failed")
        }

        return START_NOT_STICKY
    }

    // Android 15 limits dataSync foreground services. The framework grants only
    // a short cleanup window after this callback; remove the foreground state
    // and stop immediately rather than triggering a timeout crash/ANR.
    override fun onTimeout(startId: Int, fgsType: Int) {
        finishService("timeout")
    }

    private fun finishService(reason: String) {
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        onStopped?.invoke(reason)
    }

    private fun ensureChannel(name: String, description: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            val channel = manager.getNotificationChannel(CHANNEL_ID)
                ?: NotificationChannel(CHANNEL_ID, name, NotificationManager.IMPORTANCE_LOW)
            channel.name = name
            channel.description = description
            // Existing channel settings and importance remain user-controlled.
            manager.createNotificationChannel(channel)
        }
    }
}
