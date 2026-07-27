package com.example.mobile

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

/**
 * Hosts the two channels the Dart side talks to.
 *
 * The method channel handles request/response calls (start the service, apply a
 * media key, ask about permissions). The event channel is the reverse
 * direction: files shared into WeDrop and notifications posted on this phone are
 * pushed up to Dart as they happen.
 */
class MainActivity : FlutterActivity() {

    companion object {
        const val METHOD_CHANNEL = "wedrop/native"
        const val EVENT_CHANNEL = "wedrop/events"

        /** Buffers events raised before Dart has attached its listener. */
        val eventBuffer = ArrayDeque<Map<String, Any?>>()
        var eventSink: EventChannel.EventSink? = null

        /** Files shared before the engine was ready, drained by consumeSharedFiles. */
        val pendingShares = mutableListOf<String>()

        /** Emits an event to Dart, or buffers it until a listener appears. */
        fun emit(event: Map<String, Any?>) {
            val sink = eventSink
            if (sink != null) {
                sink.success(event)
            } else {
                eventBuffer.addLast(event)
            }
        }
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startService" -> {
                        val status = call.argument<String>("status") ?: "Syncing"
                        WeDropService.start(this, status)
                        result.success(null)
                    }
                    "stopService" -> {
                        WeDropService.stop(this)
                        result.success(null)
                    }
                    "updateStatus" -> {
                        WeDropService.updateStatus(this, call.argument<String>("status") ?: "")
                        result.success(null)
                    }
                    "consumeSharedFiles" -> {
                        val files = pendingShares.toList()
                        pendingShares.clear()
                        result.success(files)
                    }
                    "hasNotificationAccess" -> result.success(hasNotificationAccess())
                    "requestNotificationAccess" -> {
                        openNotificationAccessSettings()
                        result.success(null)
                    }
                    "requestPostNotifications" -> {
                        // The Flutter permission flow handles the runtime prompt;
                        // here we just report whether it is already granted.
                        result.success(NotificationHelper.canPostNotifications(this))
                    }
                    "showNotification" -> {
                        NotificationHelper.showMirrored(
                            this,
                            call.argument<String>("title") ?: "",
                            call.argument<String>("body") ?: "",
                            call.argument<String>("tag") ?: "",
                        )
                        result.success(null)
                    }
                    "mediaCommand" -> {
                        MediaController.apply(this, call.argument<String>("command") ?: "")
                        result.success(null)
                    }
                    "requestIgnoreBatteryOptimisations" -> {
                        requestIgnoreBatteryOptimisations()
                        result.success(null)
                    }
                    "deviceName" -> result.success(friendlyDeviceName())
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    eventSink = sink
                    // Flush anything raised before Dart was listening, so a share
                    // that arrived during startup is not lost.
                    while (eventBuffer.isNotEmpty()) {
                        sink?.success(eventBuffer.removeFirst())
                    }
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleShareIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleShareIntent(intent)
    }

    /**
     * Copies anything shared into WeDrop to app storage and tells Dart.
     *
     * A share intent hands over a content:// URI that is only readable while the
     * intent is alive, so the bytes must be copied out immediately rather than
     * passing the URI to Dart to open later.
     */
    private fun handleShareIntent(intent: Intent?) {
        if (intent == null) return
        if (intent.action != Intent.ACTION_SEND && intent.action != Intent.ACTION_SEND_MULTIPLE) {
            return
        }

        val uris = mutableListOf<Uri>()
        if (intent.action == Intent.ACTION_SEND) {
            @Suppress("DEPRECATION")
            (intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))?.let { uris.add(it) }
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.addAll(it) }
        }

        val copied = uris.mapNotNull { copyToCache(it) }
        if (copied.isEmpty()) return

        // Buffer for consumeSharedFiles and also push live, so it works whether
        // Dart is already running or being cold-started by the share.
        pendingShares.addAll(copied)
        emit(mapOf("type" to "shared_files", "paths" to copied))
    }

    private fun copyToCache(uri: Uri): String? {
        return try {
            val name = queryDisplayName(uri) ?: "shared-${System.currentTimeMillis()}"
            val outDir = File(cacheDir, "shared").apply { mkdirs() }
            val outFile = File(outDir, name)

            contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(outFile).use { output -> input.copyTo(output) }
            } ?: return null

            outFile.absolutePath
        } catch (e: Exception) {
            null
        }
    }

    private fun queryDisplayName(uri: Uri): String? {
        if (uri.scheme == "file") return uri.lastPathSegment
        return contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            val index = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
            if (index >= 0 && cursor.moveToFirst()) cursor.getString(index) else null
        }
    }

    private fun hasNotificationAccess(): Boolean {
        val enabled = Settings.Secure.getString(
            contentResolver, "enabled_notification_listeners",
        ) ?: return false
        return enabled.contains(packageName)
    }

    private fun openNotificationAccessSettings() {
        try {
            startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
        } catch (e: Exception) {
            startActivity(Intent(Settings.ACTION_SETTINGS))
        }
    }

    private fun requestIgnoreBatteryOptimisations() {
        try {
            val intent = Intent(
                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                Uri.parse("package:$packageName"),
            )
            startActivity(intent)
        } catch (e: Exception) {
            try {
                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            } catch (_: Exception) {
            }
        }
    }

    private fun friendlyDeviceName(): String {
        val manufacturer = Build.MANUFACTURER.replaceFirstChar { it.uppercase() }
        val model = Build.MODEL
        return if (model.startsWith(manufacturer, ignoreCase = true)) model else "$manufacturer $model"
    }
}
