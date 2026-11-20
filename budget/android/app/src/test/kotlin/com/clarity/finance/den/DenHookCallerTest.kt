package com.clarity.finance.den

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.MessageDigest

/** JVM test of the den hook's caller check (no Robolectric: its android-all jars are not cached here). */
class DenHookCallerTest {
    // A stand-in certificate whose SHA-256 we can control: the check compares digests only.
    private val other = "not den-app's key".toByteArray()

    @Test fun pinnedConstantIsTheContract() {
        assertEquals("1931299e6edfeec066087b128e0af467e702f4e48836fde8df6adbe7f35a7a07", DenHookCaller.DEN_CERT_SHA256)
        assertEquals("com.hanquest.den", DenHookCaller.DEN_PACKAGE)
    }

    @Test fun sha256HexIsLowercaseHex() {
        val want = MessageDigest.getInstance("SHA-256").digest("abc".toByteArray()).joinToString("") { "%02x".format(it) }
        assertEquals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", want)
        assertEquals(want, DenHookCaller.sha256Hex("abc".toByteArray()))
    }

    @Test fun wrongCertificateIsDenied() {
        assertFalse(DenHookCaller.isAllowed(10123, listOf("com.hanquest.den"), { listOf(other) }))
    }

    @Test fun otherPackageIsDeniedEvenWithAnyCert() {
        assertFalse(DenHookCaller.isAllowed(10123, listOf("com.evil.app"), { listOf(other) }))
        assertFalse(DenHookCaller.isAllowed(10123, null, { listOf(other) }))
        assertFalse(DenHookCaller.isAllowed(10123, listOf("com.hanquest.den"), { null }))
        assertFalse(DenHookCaller.isAllowed(10123, listOf("com.hanquest.den"), { emptyList() }))
    }

    @Test fun shellIsDeniedWithoutTheDebugAllowance() {
        assertFalse(DenHookCaller.isAllowed(2000, listOf("com.android.shell"), { listOf(other) }))
        assertTrue(DenHookCaller.isAllowed(2000, listOf("com.android.shell"), { null }, { it == 2000 }))
        assertFalse(DenHookCaller.isAllowed(10123, listOf("com.evil.app"), { null }, { it == 2000 }))
    }

    @Test fun pinnedCertMatchesAmongRotatedOnes() {
        val pinned = "den-app release cert".toByteArray()
        val pin = DenHookCaller.sha256Hex(pinned)
        val rotatedHistory = listOf("den-app old key".toByteArray(), pinned, "den-app new key".toByteArray())
        assertTrue(DenHookCaller.isAllowed(10123, listOf("com.hanquest.den"), { rotatedHistory }, pinnedSha256 = pin))
        assertTrue(DenHookCaller.isAllowed(10123, listOf("com.other.shared", "com.hanquest.den"), { if (it == "com.hanquest.den") listOf(pinned) else null }, pinnedSha256 = pin.uppercase()))
        assertFalse(DenHookCaller.isAllowed(10123, listOf("com.hanquest.den"), { listOf(other) }, pinnedSha256 = pin))
        assertFalse(DenHookCaller.isAllowed(10123, listOf("com.evil.app"), { listOf(pinned) }, pinnedSha256 = pin))
        // and with the real pin, den-app's history without that key is denied
        assertFalse(DenHookCaller.isAllowed(10123, listOf("com.hanquest.den"), { rotatedHistory }))
    }
}
