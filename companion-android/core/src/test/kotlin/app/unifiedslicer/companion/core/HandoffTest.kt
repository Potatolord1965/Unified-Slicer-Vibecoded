package app.unifiedslicer.companion.core

import app.unifiedslicer.companion.core.handoff.HandoffException
import app.unifiedslicer.companion.core.handoff.SignInCode
import app.unifiedslicer.companion.core.handoff.SignInHandoff
import app.unifiedslicer.companion.core.handoff.mergeAccounts
import app.unifiedslicer.companion.core.model.BambuAccount
import app.unifiedslicer.companion.core.model.CrealityAccount
import app.unifiedslicer.companion.core.model.ElegooAccount
import app.unifiedslicer.companion.core.model.MarkforgedAccount
import kotlinx.coroutines.test.runTest
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.Buffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.Base64

class HandoffTest {
    // Sealed by Unified Slicer's PhoneSignIn::seal (C++, OpenSSL) with key 00 01 … 1f and this id.
    private val key = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
    private val id = "AAECAwQFBgcICQoLDA0ODw"
    private val sealed = Base64.getDecoder().decode(
        "JubV3UPXYLep1kgRM+R2Qaov/rAOXDeUi9oyvgDgd2T+Ry5H4AFzsNI0s66rHRQW1XoPj4/zm4u6pW6gMoabIuboTE5hr/sQiRDRgxKHSMiKsveVLwlwpxiqZ0vI9NVlNbnJuMHzjmcREyxo7a2yaChecb1yJ7Hhr9PO1sCUtanVfJnBpOsDBxamxnjY3ELWEMt3V5ZeKy7PMgiCXw/zTnVIySvEekUdEUmUBDWiwnT9WuQk4ZqbGhtaWLPq2M8PQsaK/zXYZQ6FwAYwbA9QwPwKCK3bqnRdRyjHMHGpG9O85ImbfrBrwKuEH1aRUAWzlbAunrMNGHXEy6rt6vA5qz+hM5ed0l21mFgjcriY1f5AgkRNcx+FRUrN3qhUCoOp6PciXPqtty/gTWnq6xxhY0wFSYEbaDfxx9xH/tqJkwLCmTiseGAZXyiexqCYevMAR2ChCVEjOI7aEtzwbTaPFESHKaqmw5rpOrf0ldoNokRnrH2PjGO9+zne5+FFwVIjHRSlsejSjv7NlfSC5Ilr9VZ1b7g31CSuSyTrmwdTNV4gD+3pcpfwEecCF6vTBPCfwQyo2Xhw9E3/X3f8UbhoNxWE6Dl4UUKVfPKEmv4mYHcDjdcVZ/yUYx14Xgb+X7rJRJAuCX3Y5wriNVHNhQAJCqjuOifHr9kGKPlFiB/HQcJLlSaW5znAXaTVJYjSgOpMEZkigUBQVhkdFAo=",
    )

    private fun code(hosts: String = "192.168.1.20", port: Int = 5000) =
        SignInCode.parse("unifiedslicer://signin?v=1&h=$hosts&p=$port&i=$id&k=$key")!!

    // The test server listens on loopback, which a scanned code never names.
    private fun served(hosts: List<String>, port: Int) = SignInCode(hosts, port, id, Base64.getUrlDecoder().decode(key))

    @Test fun parsesCode() {
        val c = code("192.168.1.20,10.0.0.5")
        assertEquals(listOf("192.168.1.20", "10.0.0.5"), c.hosts)
        assertEquals(5000, c.port)
        assertEquals(32, c.key.size)
        assertNull(SignInCode.parse("https://example.com/?v=1"))
        assertNull(SignInCode.parse("unifiedslicer://signin?v=2&h=1.2.3.4&p=1&i=$id&k=$key"))
        assertNull(SignInCode.parse("unifiedslicer://signin?v=1&h=evil.example&p=1&i=$id&k=$key"))
        assertNull(SignInCode.parse("unifiedslicer://signin?v=1&h=10.1.2.3&p=1&i=$id&k=AAAA"))
        // Only addresses on the phone's own network: a link from a web page can't point the app anywhere else.
        assertNull(SignInCode.parse("unifiedslicer://signin?v=1&h=8.8.8.8&p=1&i=$id&k=$key"))
        assertNull(SignInCode.parse("unifiedslicer://signin?v=1&h=127.0.0.1&p=1&i=$id&k=$key"))
        assertEquals(listOf("172.20.0.9", "100.64.1.2"), code("8.8.8.8,172.20.0.9,172.32.0.1,100.64.1.2").hosts)
    }

    @Test fun opensWhatTheDesktopSealed() {
        val got = SignInHandoff.open(code(), sealed)
        assertEquals("DESKTOP-1", got.computer)
        assertEquals(4, got.accounts.size) // the unknown "future" service is skipped
        val b = got.accounts[0] as BambuAccount
        assertEquals(listOf("me@x", "global", "bt", "br", "42"), listOf(b.label, b.region, b.accessToken, b.refreshToken, b.uid))
        val e = got.accounts[1] as ElegooAccount
        assertEquals(listOf("CN", "et", "er", "7"), listOf(e.region, e.accessToken, e.refreshToken, e.userId))
        assertEquals(1763000000000L, e.accessExpireMs)
        val c = got.accounts[2] as CrealityAccount
        assertEquals(listOf("china", "ct", "9", "duid"), listOf(c.region, c.token, c.userId, c.deviceUid))
        val m = got.accounts[3] as MarkforgedAccount
        assertEquals(listOf("ak", "sk"), listOf(m.accessKey, m.secretKey))
    }

    @Test fun rejectsTamperedOrWrongCode() {
        val tampered = sealed.copyOf().also { it[20] = (it[20].toInt() xor 1).toByte() }
        try { SignInHandoff.open(code(), tampered); fail() } catch (_: HandoffException) {}
        val otherId = SignInCode.parse("unifiedslicer://signin?v=1&h=10.1.2.3&p=1&i=BBECAwQFBgcICQoLDA0ODw&k=$key")!!
        try { SignInHandoff.open(otherId, sealed); fail() } catch (_: HandoffException) {}
    }

    @Test fun fetchesFromTheFirstAddressThatAnswers() = runTest {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setBody(Buffer().write(sealed)))
            server.start()
            // 192.0.2.1 is a documentation address nothing answers on; the loopback server does.
            val got = SignInHandoff(OkHttpClient()).fetch(served(listOf("192.0.2.1", "127.0.0.1"), server.port))
            assertEquals(4, got.accounts.size)
            assertEquals("/signin/$id", server.takeRequest().path)
        }
    }

    @Test fun usedCodeSaysSo() = runTest {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setResponseCode(404))
            server.start()
            try {
                SignInHandoff(OkHttpClient()).fetch(served(listOf("127.0.0.1"), server.port)); fail()
            } catch (e: HandoffException) {
                assertTrue(e.message!!.contains("already used"))
            }
        }
    }

    @Test fun oversizedAnswerIsRefused() = runTest {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setBody(Buffer().write(ByteArray(2 shl 20))))
            server.start()
            try {
                SignInHandoff(OkHttpClient()).fetch(served(listOf("127.0.0.1"), server.port)); fail()
            } catch (e: HandoffException) {
                assertTrue(e.message!!.contains("too large"))
            }
        }
    }

    @Test fun importReplacesTheSameLogin() {
        val saved = listOf(BambuAccount("bambu-old", "old", accessToken = "x", uid = "42"))
        val incoming = SignInHandoff.open(code(), sealed).accounts
        val merged = mergeAccounts(saved, incoming)
        assertEquals("bambu-old", merged[0].id)
        assertEquals("bt", (merged[0] as BambuAccount).accessToken)
        assertTrue(merged.drop(1).none { it.id == "bambu-old" })
    }
}
