package com.clarity.finance.den

/** PROFILE BUILDS (src/profile): no caller but den-app, checked in DenHookCaller. The adb shell allowance lives in src/debug only. */
object DenHookBuild {
    @Suppress("UNUSED_PARAMETER")
    fun extraAllowed(uid: Int): Boolean = false
}
