package com.clarity.finance.den

/** RELEASE BUILDS (src/release): no caller but den-app, checked in DenHookCaller. The adb shell allowance lives in src/debug only. */
object DenHookBuild {
    @Suppress("UNUSED_PARAMETER")
    fun extraAllowed(uid: Int): Boolean = false
}
