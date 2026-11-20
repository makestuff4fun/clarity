package com.clarity.finance.den

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * Runs a den hook call in Clarity's own Dart code, from a binder thread.
 *
 * - Clarity open (MainActivity attached its engine): the call goes to the app's engine, so it
 *   uses the app's one FinanceDatabase and its drift streams show the new row at once.
 * - Clarity not open: a headless FlutterEngine is started on the Dart entrypoint
 *   `denHookMain` (lib/main.dart). No activity, no window. It is stopped after [IDLE_MS]
 *   without calls, or as soon as the app's own engine attaches, so the database has one
 *   writer at a time.
 *
 * Dart registers its channel handler only once the database is open; until then a call
 * answers "not implemented" and is retried. After [TIMEOUT_MS] the answer is `busy`.
 * All engine work happens on the main looper; the binder thread only waits.
 */
object DenHookEngine {
    const val CHANNEL = "com.clarity.finance/den_hook"
    const val TIMEOUT_MS = 10_000L
    const val IDLE_MS = 120_000L
    private const val TAG = DenHookProvider.TAG
    private const val ENTRYPOINT = "denHookMain"

    private val main = Handler(Looper.getMainLooper())
    private val inFlight = AtomicInteger()

    @Volatile private var ui: MethodChannel? = null

    // Main looper only.
    private var headless: FlutterEngine? = null
    private var headlessChannel: MethodChannel? = null
    private var loaderStarting = false

    private val idleStop = Runnable { if (inFlight.get() == 0) stopHeadless() }

    fun error(code: String, message: String): String =
        JSONObject().put("ok", false).put("error", code).put("message", message).toString()

    /** MainActivity.configureFlutterEngine. */
    fun attachUi(engine: FlutterEngine) {
        ui = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        main.post { if (inFlight.get() == 0) stopHeadless() }
    }

    /** MainActivity.cleanUpFlutterEngine. */
    fun detachUi() {
        ui = null
    }

    private class Box {
        @Volatile var answer: String? = null
        @Volatile var failed = false
    }

    /** On a binder thread; never the main thread. */
    fun call(context: Context, method: String, arg: String?): String {
        check(Looper.myLooper() != Looper.getMainLooper())
        val deadline = SystemClock.uptimeMillis() + TIMEOUT_MS
        inFlight.incrementAndGet()
        try {
            while (true) {
                val left = deadline - SystemClock.uptimeMillis()
                if (left <= 0) break
                val box = Box()
                val done = CountDownLatch(1)
                main.post {
                    val channel = ui ?: ensureHeadless(context)
                    if (channel == null) {
                        done.countDown() // still starting: try again
                        return@post
                    }
                    channel.invokeMethod("call", mapOf("method" to method, "arg" to arg),
                        object : MethodChannel.Result {
                            override fun success(result: Any?) {
                                box.answer = result as? String
                                box.failed = result !is String
                                done.countDown()
                            }

                            override fun error(code: String, msg: String?, details: Any?) {
                                box.failed = true
                                done.countDown()
                            }

                            override fun notImplemented() = done.countDown() // not ready yet
                        })
                }
                if (!done.await(left, TimeUnit.MILLISECONDS)) break
                box.answer?.let { return it }
                if (box.failed) {
                    Log.w(TAG, "method=$method failed in Dart")
                    return error("failed", "Clarity could not do that.")
                }
                Thread.sleep(minOf(100L, maxOf(1L, deadline - SystemClock.uptimeMillis())))
            }
            Log.w(TAG, "method=$method busy after ${TIMEOUT_MS}ms")
            return error("busy", "Clarity could not answer in 10 seconds.")
        } finally {
            inFlight.decrementAndGet()
            main.removeCallbacks(idleStop)
            main.postDelayed(idleStop, IDLE_MS)
        }
    }

    /** Main looper. Null while Flutter's loader is still starting. */
    private fun ensureHeadless(context: Context): MethodChannel? {
        headlessChannel?.let { return it }
        val loader = FlutterInjector.instance().flutterLoader()
        if (!loader.initialized()) {
            if (!loaderStarting) {
                loaderStarting = true
                loader.startInitialization(context)
                loader.ensureInitializationCompleteAsync(context, null, main) { loaderStarting = false }
            }
            return null
        }
        val engine = FlutterEngine(context) // registers the app's plugins; no activity
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(loader.findAppBundlePath(), ENTRYPOINT))
        headless = engine
        headlessChannel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        Log.i(TAG, "headless engine started")
        return headlessChannel
    }

    private fun stopHeadless() {
        val engine = headless ?: return
        headless = null
        headlessChannel = null
        engine.destroy()
        Log.i(TAG, "headless engine stopped")
    }
}
