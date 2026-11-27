package com.termpulse.termpulse

import android.Manifest
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.termpulse.termpulse/foreground"
    private val notificationPermissionRequestCode = 4202
    private var usbSerialBridge: UsbSerialBridge? = null
    private var notificationPermissionResult: MethodChannel.Result? = null
    private var foregroundChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        usbSerialBridge = UsbSerialBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        foregroundChannel = channel
        SshForegroundService.onStopped = { reason ->
            channel.invokeMethod("foregroundServiceStopped", mapOf("reason" to reason))
        }
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startService" -> {
                    val count = call.argument<Int>("count") ?: 1
                    val strings = call.argument<Map<String, String>>("strings") ?: emptyMap()
                    try {
                        if (count > 0) {
                            SshForegroundService.startOrUpdate(this, count, strings)
                        } else {
                            SshForegroundService.stop(this)
                        }
                        result.success(true)
                    } catch (error: RuntimeException) {
                        // Background-start restrictions and permission failures are
                        // surfaced to Flutter so it can report the actual capability.
                        result.error("foreground_start_failed", error.message, null)
                    }
                }
                "stopService" -> {
                    SshForegroundService.stop(this)
                    result.success(true)
                }
                "getDataDir" -> {
                    result.success(filesDir.absolutePath)
                }
                "getNotificationPermissionStatus" -> {
                    result.success(notificationPermissionStatus())
                }
                "requestNotificationPermission" -> {
                    requestNotificationPermission(result)
                }
                "openNotificationSettings" -> {
                    try {
                        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                        } else {
                            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                                .setData(Uri.parse("package:$packageName"))
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (error: RuntimeException) {
                        result.error("notification_settings_failed", error.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun notificationPermissionStatus(): Map<String, Boolean> {
        val required = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
        val granted = !required || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        val shouldShowRationale = required &&
            shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS)
        val requestedBefore = getSharedPreferences("foreground_notification", MODE_PRIVATE)
            .getBoolean("notification_permission_requested", false)
        val manager = getSystemService(NotificationManager::class.java)
        val channelEnabled = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = manager.getNotificationChannel(SshForegroundService.CHANNEL_ID)
            channel == null || channel.importance != NotificationManager.IMPORTANCE_NONE
        } else {
            true
        }
        return mapOf(
            "required" to required,
            "granted" to granted,
            "notificationsEnabled" to manager.areNotificationsEnabled(),
            "channelEnabled" to channelEnabled,
            "canRequest" to (required && !granted && (!requestedBefore || shouldShowRationale)),
            "shouldShowRationale" to shouldShowRationale
        )
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (notificationPermissionResult != null) {
            result.error("notification_request_in_progress", "A notification permission request is already open.", null)
            return
        }
        val status = notificationPermissionStatus()
        if (status["canRequest"] != true) {
            result.success(status)
            return
        }
        // This method is called only after an explicit action in Flutter's
        // permission explanation; connecting to a host never opens a prompt.
        notificationPermissionResult = result
        try {
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                notificationPermissionRequestCode
            )
        } catch (error: RuntimeException) {
            notificationPermissionResult = null
            result.error("notification_request_failed", error.message, null)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != notificationPermissionRequestCode) return
        // An empty result means the OS dialog was dismissed, so allow the user
        // to ask again later instead of treating dismissal as permanent denial.
        if (grantResults.isNotEmpty()) {
            getSharedPreferences("foreground_notification", MODE_PRIVATE)
                .edit().putBoolean("notification_permission_requested", true).apply()
        }
        val pending = notificationPermissionResult
        notificationPermissionResult = null
        pending?.success(notificationPermissionStatus())
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        notificationPermissionResult?.error(
            "notification_request_cancelled", "The activity was detached during the permission request.", null
        )
        notificationPermissionResult = null
        foregroundChannel?.setMethodCallHandler(null)
        foregroundChannel = null
        SshForegroundService.onStopped = null
        usbSerialBridge?.dispose()
        usbSerialBridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
