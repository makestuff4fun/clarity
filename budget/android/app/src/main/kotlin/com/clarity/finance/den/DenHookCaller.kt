package com.clarity.finance.den

import java.security.MessageDigest

/**
 * Who may call the den hook (den-app docs/MONEY.md, "The hook, as pinned (2026-11-20)"):
 * only the package com.hanquest.den signed with den-app's release key. Pure, so a JVM test
 * covers it; DenHookProvider feeds it from PackageManager on every call.
 */
object DenHookCaller {
    const val DEN_PACKAGE = "com.hanquest.den"

    /** SHA-256 of den-app's release signing certificate. Pinned: never change it here alone. */
    const val DEN_CERT_SHA256 = "1931299e6edfeec066087b128e0af467e702f4e48836fde8df6adbe7f35a7a07"

    fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    /**
     * [packages]: PackageManager.getPackagesForUid(uid). [certsOf]: a package's signing
     * certificates, the current signers plus the rotation history (so a key den-app rotated
     * away from the pinned one, or to it, still matches). [extraAllowed]: debug builds let the
     * adb shell uid through (DenHookBuild, src/debug only); release and profile say false.
     */
    fun isAllowed(
        uid: Int,
        packages: List<String>?,
        certsOf: (String) -> List<ByteArray>?,
        extraAllowed: (Int) -> Boolean = { false },
        pinnedSha256: String = DEN_CERT_SHA256, // a parameter only so the JVM test can use a known cert
    ): Boolean {
        if (extraAllowed(uid)) return true
        if (packages == null || DEN_PACKAGE !in packages) return false
        val certs = certsOf(DEN_PACKAGE) ?: return false
        return certs.any { sha256Hex(it).equals(pinnedSha256, ignoreCase = true) }
    }
}
