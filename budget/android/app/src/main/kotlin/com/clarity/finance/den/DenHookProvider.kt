package com.clarity.finance.den

import android.content.ContentProvider
import android.content.ContentValues
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Build
import android.os.Bundle
import android.os.Looper
import android.util.Log

/**
 * content://com.clarity.finance.den: the den-app hook. ContentResolver.call only; every
 * answer is a Bundle with one string, "json". The caller is checked here on every call;
 * the work is done by Clarity's own Dart code (DenHookEngine, lib/struct/denHook.dart).
 * Logs carry the method, the uid and the error code only: never an amount, title or note.
 */
class DenHookProvider : ContentProvider() {
    override fun onCreate(): Boolean = true // nothing starts until a call comes

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle {
        val ctx = context ?: return answer(DenHookEngine.error("failed", "Clarity is not ready."))
        val uid = Binder.getCallingUid()
        val pm = ctx.packageManager
        val allowed = try {
            DenHookCaller.isAllowed(uid, pm.getPackagesForUid(uid)?.toList(), { certsOf(pm, it) },
                DenHookBuild::extraAllowed)
        } catch (e: Exception) {
            false
        }
        if (!allowed) {
            Log.w(TAG, "denied method=$method uid=$uid")
            return answer(DenHookEngine.error("denied", "Only den-app may use this."))
        }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            // Never wait on the main thread (a cross-process call is always on a binder thread).
            return answer(DenHookEngine.error("failed", "Called on the main thread."))
        }
        val json = DenHookEngine.call(ctx.applicationContext, method, arg)
        return answer(json)
    }

    private fun answer(json: String) = Bundle().apply { putString("json", json) }

    @Suppress("DEPRECATION")
    private fun certsOf(pm: PackageManager, pkg: String): List<ByteArray>? = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val info = pm.getPackageInfo(pkg, PackageManager.GET_SIGNING_CERTIFICATES).signingInfo
            when {
                info == null -> null
                info.hasMultipleSigners() -> info.apkContentsSigners?.map { it.toByteArray() }
                else -> info.signingCertificateHistory?.map { it.toByteArray() }
            }
        } else {
            pm.getPackageInfo(pkg, PackageManager.GET_SIGNATURES).signatures?.map { it.toByteArray() }
        }
    } catch (e: PackageManager.NameNotFoundException) {
        null
    }

    // No tables: the hook is call() only.
    override fun query(uri: Uri, p: Array<out String>?, s: String?, a: Array<out String>?, o: String?): Cursor? = null
    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, s: String?, a: Array<out String>?): Int = 0
    override fun update(uri: Uri, v: ContentValues?, s: String?, a: Array<out String>?): Int = 0

    companion object {
        const val TAG = "clarity-den"
    }
}
