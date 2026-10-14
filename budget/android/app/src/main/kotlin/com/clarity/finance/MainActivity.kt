package com.clarity.finance

import android.os.Handler
import android.os.Looper
import com.clarity.finance.update.ApkInstaller
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity: FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The self-update: Dart downloads and sha256-verifies the APK, this hands it to PackageInstaller.
        // "install" {path} answers true once the session is committed, false when Clarity may not
        // install apps yet (the setting is opened for Brian).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.clarity.finance/update")
            .setMethodCallHandler { call, result ->
                if (call.method != "install") return@setMethodCallHandler result.notImplemented()
                val path = call.argument<String>("path")
                val apk = path?.let(::File)
                if (apk == null || !apk.isFile) return@setMethodCallHandler result.error("no-apk", "no APK at $path", null)
                if (!ApkInstaller.canInstall(this)) {
                    ApkInstaller.openPermission(this)
                    return@setMethodCallHandler result.success(false)
                }
                val main = Handler(Looper.getMainLooper())
                Thread {
                    try {
                        ApkInstaller.install(applicationContext, apk)
                        main.post { result.success(true) }
                    } catch (e: Exception) {
                        main.post { result.error("install-failed", e.message, null) }
                    }
                }.start()
            }
    }
}
