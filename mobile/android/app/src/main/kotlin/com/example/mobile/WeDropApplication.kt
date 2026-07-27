package com.example.mobile

import android.app.Application
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugins.GeneratedPluginRegistrant

/**
 * Owns a single [FlutterEngine] for the whole process lifetime, started as soon
 * as the app process exists rather than when an Activity first appears.
 *
 * Flutter's default wiring ties the engine — and everything running inside it,
 * including discovery, TCP sessions and every timer — to whichever Activity
 * happens to host it, and destroys the engine when that Activity is destroyed.
 * Android destroys the Activity the moment a user swipes WeDrop out of Recents,
 * so that default behaviour silently killed every connection right then, even
 * though the ongoing foreground-service notification kept claiming the app was
 * still syncing.
 *
 * Owning the engine here instead means it survives Activity destruction for as
 * long as the process itself survives — which [WeDropService]'s foreground
 * status is what protects. [MainActivity] attaches to this same engine via
 * [MainActivity.provideFlutterEngine] rather than creating its own, so
 * `main()` — and the single [AppService] instance it starts — runs exactly
 * once per process, independent of how many times the UI is opened and closed.
 */
class WeDropApplication : Application() {

    lateinit var flutterEngine: FlutterEngine
        private set

    override fun onCreate() {
        super.onCreate()

        flutterEngine = FlutterEngine(this)
        GeneratedPluginRegistrant.registerWith(flutterEngine)
        // Runs Dart's main() now, with no Activity attached yet. AppService.start()
        // does not need one — only the pieces that show native UI (file picker,
        // permission prompts, the share-intent handler) need an Activity, and
        // those simply wait until one attaches.
        flutterEngine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
    }
}
