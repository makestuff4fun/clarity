package com.clarity.finance.den

import android.os.Process
import android.util.Log

/**
 * DEBUG BUILDS ONLY (src/debug). Lets the adb shell uid call the den hook, so a debug APK can
 * be exercised with `adb shell content call --uri content://com.clarity.finance.den ...`.
 * src/release and src/profile hold a DenHookBuild that allows nobody; check_den_hook.sh proves
 * this string is not in the release APK.
 */
object DenHookBuild {
    fun extraAllowed(uid: Int): Boolean {
        if (uid != Process.SHELL_UID) return false
        Log.w(DenHookProvider.TAG, "den-hook-debug-shell-allowance: adb shell let through (debug build)")
        return true
    }
}
