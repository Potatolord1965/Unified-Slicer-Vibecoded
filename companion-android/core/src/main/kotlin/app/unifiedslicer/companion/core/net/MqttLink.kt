package app.unifiedslicer.companion.core.net

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.eclipse.paho.client.mqttv3.IMqttDeliveryToken
import org.eclipse.paho.client.mqttv3.MqttCallbackExtended
import org.eclipse.paho.client.mqttv3.MqttClient
import org.eclipse.paho.client.mqttv3.MqttConnectOptions
import org.eclipse.paho.client.mqttv3.MqttException
import org.eclipse.paho.client.mqttv3.MqttMessage
import org.eclipse.paho.client.mqttv3.persist.MemoryPersistence
import java.io.Closeable
import java.io.IOException
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import javax.net.ssl.SSLSocketFactory

/**
 * A kept-open MQTT connection (Eclipse Paho). Subscribes [topics] on every (re)connect and then
 * calls [onConnected], e.g. to ask the printer for a full status.
 *
 * [tls] replaces the system's certificate and host name checks, for a printer on the local network
 * that is reached by its IP address (Bambu LAN mode, [bambuPrinterSocketFactory]). Cloud brokers
 * leave it null and are checked as usual.
 */
class MqttLink(
    private val uri: String,
    private val username: String,
    private val password: String,
    private val topics: List<String>,
    private val tls: SSLSocketFactory? = null,
    clientId: String = "usc-" + UUID.randomUUID().toString().take(12),
    private val onConnected: (MqttLink) -> Unit = {},
    private val onMessage: (topic: String, payload: String) -> Unit,
) : Closeable {
    private val client = MqttClient(uri, clientId, MemoryPersistence())
    // Paho must not be called back into from its own callback thread.
    private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "mqtt-$clientId").apply { isDaemon = true } }
    @Volatile private var closed = false

    val isConnected: Boolean get() = client.isConnected

    init {
        client.setCallback(object : MqttCallbackExtended {
            override fun connectComplete(reconnect: Boolean, serverURI: String?) {
                worker.execute {
                    runCatching {
                        if (topics.isNotEmpty()) client.subscribe(topics.toTypedArray(), IntArray(topics.size) { 0 })
                        onConnected(this@MqttLink)
                    }
                }
            }

            override fun connectionLost(cause: Throwable?) {}
            override fun deliveryComplete(token: IMqttDeliveryToken?) {}
            override fun messageArrived(topic: String, message: MqttMessage) {
                runCatching { onMessage(topic, String(message.payload, Charsets.UTF_8)) }
            }
        })
    }

    /** Connects if not connected. Throws on failure; a bad user name or password becomes [AuthException]. */
    suspend fun ensureConnected() = withContext(Dispatchers.IO) {
        if (closed || client.isConnected) return@withContext
        val opts = MqttConnectOptions().apply {
            userName = username
            password = this@MqttLink.password.toCharArray()
            isCleanSession = true
            isAutomaticReconnect = true
            connectionTimeout = 10
            keepAliveInterval = 30
            if (uri.startsWith("ssl://")) {
                socketFactory = tls ?: SSLSocketFactory.getDefault()
                isHttpsHostnameVerificationEnabled = tls == null
            }
        }
        try {
            client.connect(opts)
        } catch (e: MqttException) {
            if (e.reasonCode == MqttException.REASON_CODE_FAILED_AUTHENTICATION.toInt() ||
                e.reasonCode == MqttException.REASON_CODE_NOT_AUTHORIZED.toInt()
            ) throw AuthException("The printer or broker rejected the credentials")
            throw IOException("Could not connect to ${uri.substringAfter("://")}: ${e.message ?: e.reasonCode}", e)
        }
    }

    /** Fire and forget, for status requests (and the only way from [onConnected], which runs on the worker). */
    fun publish(topic: String, payload: String) {
        if (closed) return
        worker.execute { runCatching { if (client.isConnected) client.publish(topic, payload.toByteArray(), 0, false) } }
    }

    /** Publishes and waits until the message has gone out; throws [IOException] when it couldn't be sent. */
    suspend fun send(topic: String, payload: String) {
        val sent = CompletableDeferred<Unit>()
        try {
            if (closed) throw RejectedExecutionException()
            worker.execute {
                try {
                    if (!client.isConnected) throw IOException("Not connected to ${uri.substringAfter("://")}")
                    client.publish(topic, payload.toByteArray(), 0, false)
                    sent.complete(Unit)
                } catch (e: Exception) {
                    sent.completeExceptionally(e)
                }
            }
        } catch (e: RejectedExecutionException) {
            throw IOException("The connection is closed", e)
        }
        try {
            sent.await()
        } catch (e: MqttException) {
            throw IOException("Could not send to ${uri.substringAfter("://")}: ${e.message ?: e.reasonCode}", e)
        }
    }

    override fun close() {
        closed = true
        worker.execute {
            runCatching { if (client.isConnected) client.disconnect(2000) }
            runCatching { client.close(true) }
        }
        worker.shutdown()
    }
}
