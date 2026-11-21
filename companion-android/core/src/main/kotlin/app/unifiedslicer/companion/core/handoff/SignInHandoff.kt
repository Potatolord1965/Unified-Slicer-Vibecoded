package app.unifiedslicer.companion.core.handoff

import app.unifiedslicer.companion.core.model.Account
import app.unifiedslicer.companion.core.model.BambuAccount
import app.unifiedslicer.companion.core.model.CrealityAccount
import app.unifiedslicer.companion.core.model.ElegooAccount
import app.unifiedslicer.companion.core.model.MarkforgedAccount
import app.unifiedslicer.companion.core.net.USER_AGENT
import app.unifiedslicer.companion.core.net.arr
import app.unifiedslicer.companion.core.net.long
import app.unifiedslicer.companion.core.net.parseJson
import app.unifiedslicer.companion.core.net.str
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.ResponseBody
import okio.Buffer
import java.io.IOException
import java.net.URI
import java.util.Base64
import java.util.UUID
import java.util.concurrent.TimeUnit
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * The QR code Unified Slicer shows under Accounts > Sign in on phone:
 * `unifiedslicer://signin?v=1&h=<IPv4,...>&p=<port>&i=<offer id>&k=<AES-256 key>` (base64url).
 * The computer serves its sign-ins once at `http://<h>:<p>/signin/<i>`, sealed with AES-GCM under
 * the key, which only travels in the QR code. See docs/HLSD/phone-sign-in.md in the repository.
 */
class SignInCode(val hosts: List<String>, val port: Int, val id: String, val key: ByteArray) {
    companion object {
        fun parse(text: String): SignInCode? = runCatching {
            val uri = URI(text.trim())
            if (uri.scheme != "unifiedslicer" || uri.authority != "signin") return null
            val q = uri.rawQuery.orEmpty().split('&').mapNotNull {
                val eq = it.indexOf('=')
                if (eq <= 0) null else it.substring(0, eq) to it.substring(eq + 1)
            }.toMap()
            if (q["v"] != "1") return null
            // A link anyone can open: only addresses on the phone's own network are ever fetched from.
            val hosts = q["h"].orEmpty().split(',').filter { it.matches(IPV4) && isLocalNetwork(it) }
            val port = q["p"]?.toIntOrNull()?.takeIf { it in 1..65535 } ?: return null
            val id = q["i"]?.takeIf { it.matches(B64URL) } ?: return null
            val key = Base64.getUrlDecoder().decode(q["k"] ?: return null)
            if (hosts.isEmpty() || key.size != 32) return null
            SignInCode(hosts, port, id, key)
        }.getOrNull()

        private val IPV4 = Regex("""\d{1,3}(\.\d{1,3}){3}""")
        private val B64URL = Regex("""[A-Za-z0-9_-]{16,64}""")
    }
}

/**
 * Addresses a computer on the same network can have: the private ranges, carrier-grade NAT
 * (100.64/10) and link-local, as the computer's own server accepts.
 */
fun isLocalNetwork(ip: String): Boolean {
    val b = ip.split('.').map { it.toIntOrNull() ?: return false }
    if (b.size != 4 || b.any { it !in 0..255 }) return false
    return b[0] == 10 || (b[0] == 172 && b[1] in 16..31) || (b[0] == 192 && b[1] == 168) ||
        (b[0] == 100 && b[1] in 64..127) || (b[0] == 169 && b[1] == 254)
}

/** What the computer handed over. [accounts] carry new ids; see [mergeAccounts]. */
class HandedOver(val computer: String, val accounts: List<Account>)

class SignInHandoff(http: OkHttpClient) {
    // Same network only: an address that doesn't answer fast is the wrong one, so try the next.
    private val http = http.newBuilder()
        .connectTimeout(4, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .callTimeout(15, TimeUnit.SECONDS)
        .build()

    /** Fetches and opens the offer, trying each of the computer's addresses. */
    suspend fun fetch(code: SignInCode): HandedOver = withContext(Dispatchers.IO) {
        var last: IOException? = null
        for (host in code.hosts) {
            val request = Request.Builder().url("http://$host:${code.port}/signin/${code.id}").header("User-Agent", USER_AGENT).build()
            try {
                http.newCall(request).execute().use { r ->
                    when {
                        r.code == 404 -> throw HandoffException("This code was already used or has expired. Make a new one on the computer.")
                        !r.isSuccessful -> throw IOException("HTTP ${r.code}")
                        else -> return@withContext open(code, readCapped(r.body!!))
                    }
                }
            } catch (e: HandoffException) {
                throw e
            } catch (e: IOException) {
                last = e
            }
        }
        throw HandoffException(
            "Couldn't reach the computer. Check that the phone is on the same Wi-Fi, and that the computer's firewall allows Unified Slicer.",
            last,
        )
    }

    companion object {
        /** A sealed offer is a few kilobytes; anything far bigger isn't one. */
        private const val MAX_OFFER = 1L shl 20

        private fun readCapped(body: ResponseBody): ByteArray {
            val buf = Buffer()
            body.source().use { src -> while (buf.size <= MAX_OFFER && src.read(buf, 8192) != -1L) Unit }
            if (buf.size > MAX_OFFER) throw HandoffException("The answer is too large to be a sign-in. Make a new code on the computer.")
            return buf.readByteArray()
        }

        /** Decrypts a served offer and reads its accounts. */
        fun open(code: SignInCode, sealed: ByteArray): HandedOver {
            if (sealed.size < NONCE + TAG) throw HandoffException("The computer sent an incomplete answer.")
            val plain = try {
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(code.key, "AES"), GCMParameterSpec(TAG * 8, sealed, 0, NONCE))
                cipher.updateAAD(("unified-signin-v1:" + code.id).toByteArray())
                cipher.doFinal(sealed, NONCE, sealed.size - NONCE)
            } catch (e: AEADBadTagException) {
                throw HandoffException("The answer didn't match this code. Make a new code on the computer.", e)
            }
            try {
                return read(String(plain, Charsets.UTF_8))
            } finally {
                plain.fill(0)
            }
        }

        /** The payload: `{"v":1,"computer":"…","accounts":[{"service":"bambu",…},…]}`. Unknown services are skipped. */
        fun read(json: String): HandedOver {
            val root = parseJson(json) ?: throw HandoffException("The computer sent something this app can't read.")
            val accounts = root.arr("accounts").orEmpty().mapNotNull { a ->
                val label = a.str("label")
                when (a.str("service")) {
                    "bambu" -> BambuAccount(
                        id = "bambu-" + UUID.randomUUID(),
                        label = label ?: "Bambu Lab",
                        region = a.str("region") ?: "global",
                        accessToken = a.str("access_token") ?: return@mapNotNull null,
                        refreshToken = a.str("refresh_token").orEmpty(),
                        uid = a.str("user_id") ?: return@mapNotNull null,
                    )
                    "elegoo" -> ElegooAccount(
                        id = "elegoo-" + UUID.randomUUID(),
                        label = label ?: "Elegoo",
                        region = a.str("region") ?: "global",
                        accessToken = a.str("access_token") ?: return@mapNotNull null,
                        refreshToken = a.str("refresh_token").orEmpty(),
                        accessExpireMs = a.long("access_expire_ms") ?: 0,
                        userId = a.str("user_id") ?: return@mapNotNull null,
                    )
                    "creality" -> CrealityAccount(
                        id = "creality-" + UUID.randomUUID(),
                        label = label ?: "Creality Cloud",
                        region = a.str("region") ?: "global",
                        token = a.str("token") ?: return@mapNotNull null,
                        userId = a.str("user_id") ?: return@mapNotNull null,
                        deviceUid = a.str("device_uid") ?: return@mapNotNull null,
                    )
                    "markforged" -> MarkforgedAccount(
                        id = "markforged-" + UUID.randomUUID(),
                        label = label ?: "Markforged Eiger",
                        accessKey = a.str("access_key") ?: return@mapNotNull null,
                        secretKey = a.str("secret_key") ?: return@mapNotNull null,
                    )
                    else -> null
                }
            }
            return HandedOver(root.str("computer") ?: "your computer", accounts)
        }

        private const val NONCE = 12
        private const val TAG = 16
    }
}

class HandoffException(message: String, cause: Throwable? = null) : IOException(message, cause)

/** The same account on another sign-in, so an import replaces it rather than listing it twice. */
fun Account.sameLogin(other: Account): Boolean = when {
    this is BambuAccount && other is BambuAccount -> uid == other.uid && region == other.region
    this is ElegooAccount && other is ElegooAccount -> userId == other.userId && region == other.region
    this is CrealityAccount && other is CrealityAccount -> userId == other.userId && region == other.region
    this is MarkforgedAccount && other is MarkforgedAccount -> accessKey == other.accessKey
    else -> false
}

/** [incoming] with each account that is already saved taking over that saved account's id. */
fun mergeAccounts(saved: List<Account>, incoming: List<Account>): List<Account> = incoming.map { a ->
    val existing = saved.firstOrNull { it.sameLogin(a) } ?: return@map a
    when (a) {
        is BambuAccount -> a.copy(id = existing.id)
        is ElegooAccount -> a.copy(id = existing.id)
        is CrealityAccount -> a.copy(id = existing.id)
        is MarkforgedAccount -> a.copy(id = existing.id)
        else -> a
    }
}
