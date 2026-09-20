package com.example.android_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.ContentValues
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.provider.MediaStore
import android.util.Log
import androidx.core.app.NotificationCompat
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import org.json.JSONObject
import java.io.ByteArrayOutputStream

class ClipboardService : Service() {

    companion object {
        private const val TAG = "ClipboardService"
        private const val CHANNEL_ID = "clipboard_sync_channel"
        private const val NOTIFICATION_ID = 1
        const val ACTION_ACCEPT_IMAGE = "com.example.android_app.ACCEPT_IMAGE"
        const val ACTION_REJECT_IMAGE = "com.example.android_app.REJECT_IMAGE"
        const val ACTION_CANCEL_IMAGE_TRANSFERS =
            "com.example.android_app.CANCEL_IMAGE_TRANSFERS"
        const val ACTION_CANCEL_INCOMING_IMAGE_OFFERS =
            "com.example.android_app.CANCEL_INCOMING_IMAGE_OFFERS"
        const val ACTION_CHECK_CLIPBOARD_IMAGE =
            "com.example.android_app.CHECK_CLIPBOARD_IMAGE"
        private const val IMAGE_LIMIT_BYTES = 20 * 1024 * 1024
    }

    private var webSocket: WebSocket? = null
    private var client: OkHttpClient? = null
    private var clipboardManager: ClipboardManager? = null
    private var clipboardListener: ClipboardManager.OnPrimaryClipChangedListener? = null
    private var lastClipboardText = ""
    private var serverIp = ""
    private var serverPort = 8080
    private var serverFingerprint = ""
    private var serverName = "Saved Mac"
    private var pairingCode: String? = null
    private lateinit var pairingStore: PairingStore
    private var pairingSecret: String? = null
    private var syncAuthenticated = false
    private val connectionPreferences by lazy {
        getSharedPreferences("clipboard_sync_connection", Context.MODE_PRIVATE)
    }
    private val imageOfferPreferences by lazy {
        getSharedPreferences("clipboard_sync_image_offer", Context.MODE_PRIVATE)
    }
    private data class ImageOffer(
        val id: String,
        val name: String,
        val mime: String,
        val size: Long,
        val sha256: String
    )
    private data class OutgoingImage(
        val bytes: ByteArray,
        val name: String,
        val mime: String
    )
    private val pendingImageOffers = mutableMapOf<String, ImageOffer>()
    private val incomingImages = mutableMapOf<String, ByteArrayOutputStream>()
    private var imageOfferExpiry: Runnable? = null
    private val outgoingImages = mutableMapOf<String, OutgoingImage>()
    private val outgoingImageTimers = mutableMapOf<String, Runnable>()
    private var lastReceivedImageUri: String? = null
    private var reconnectDelay = 1000L
    private val maxDelay = 32000L
    private val handler = Handler(Looper.getMainLooper())
    private var shouldReconnect = true
    private val pairingTimeout = Runnable {
        if (!syncAuthenticated && pairingCode != null) {
            Log.e(TAG, "Pairing timed out before the Mac accepted the code")
            shouldReconnect = false
            webSocket?.close(1008, "Pairing timed out")
            webSocket = null
            publishStatus(
                "error",
                "Pairing timed out. Generate a new Mac code and try again."
            )
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    private data class LatencyPayload(val sentAt: Long?, val text: String)

    private fun wrapLatencyPayload(text: String): String {
        return "CS1|${System.currentTimeMillis()}|$text"
    }

    private fun unwrapLatencyPayload(raw: String): LatencyPayload {
        if (!raw.startsWith("CS1|")) {
            return LatencyPayload(null, raw)
        }
        val secondBar = raw.indexOf('|', 4)
        if (secondBar < 0) {
            return LatencyPayload(null, raw)
        }
        val sentAt = raw.substring(4, secondBar).toLongOrNull()
        return LatencyPayload(sentAt, raw.substring(secondBar + 1))
    }

    private fun stripAllLatencyPrefixes(raw: String): String {
        var text = raw
        var guard = 0
        while (text.startsWith("CS1|") && guard < 64) {
            val next = unwrapLatencyPayload(text).text
            if (next == text) break
            text = next
            guard++
        }
        return text
    } 

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Handle explicit STOP action first
        if (intent?.action == "STOP") {
            shouldReconnect = false
            cancelAllImageTransfers("Sync stopped")
            handler.removeCallbacksAndMessages(null)
            webSocket?.cancel()  // Stronger than close()
            webSocket = null
            clearSavedConnection()
            publishStatus("stopped", "Sync is stopped")
            stopForeground(STOP_FOREGROUND_REMOVE)  // Remove notification
            stopSelf()  // Kill service immediately
            Log.i(TAG, "Service stopped via STOP action")
            return START_NOT_STICKY
        }

        when (intent?.action) {
            ACTION_ACCEPT_IMAGE -> {
                intent.getStringExtra("IMAGE_ID")?.let { acceptImage(it) }
                return START_STICKY
            }
            ACTION_REJECT_IMAGE -> {
                intent.getStringExtra("IMAGE_ID")?.let { rejectImage(it) }
                return START_STICKY
            }
            ACTION_CANCEL_IMAGE_TRANSFERS -> {
                cancelAllImageTransfers(
                    intent.getStringExtra("REASON") ?: "Clipboard Sync is not open on Android"
                )
                return START_STICKY
            }
            ACTION_CANCEL_INCOMING_IMAGE_OFFERS -> {
                val reason = intent.getStringExtra("REASON")
                    ?: "Clipboard Sync is not open on Android"
                pendingImageOffers.keys.toList().forEach { rejectImage(it, reason) }
                return START_STICKY
            }
            ACTION_CHECK_CLIPBOARD_IMAGE -> {
                clipboardManager = clipboardManager
                    ?: getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                clipboardManager?.primaryClip?.let(::offerClipboardImage)
                return START_STICKY
            }
        }

        // Get server IP and port from Intent
        val startedWithConnection = intent?.hasExtra("SERVER_IP") == true
        if (startedWithConnection) {
            // The Flutter UI may be restarted while this foreground service is
            // still alive. A new Start Sync / Pair action must replace the old
            // socket; otherwise the new code is never sent to the Mac.
            handler.removeCallbacksAndMessages(null)
            webSocket?.cancel()
            webSocket = null
            client?.dispatcher?.executorService?.shutdown()
            client = null
            syncAuthenticated = false
            serverIp = intent?.getStringExtra("SERVER_IP") ?: ""
            serverPort = intent?.getIntExtra("SERVER_PORT", 8080) ?: 8080
            serverFingerprint = normalizeFingerprint(
                intent?.getStringExtra("SERVER_FINGERPRINT") ?: ""
            )
            serverName = intent?.getStringExtra("SERVER_NAME") ?: "Saved Mac"
            pairingCode = intent?.getStringExtra("PAIRING_CODE")?.takeIf { it.isNotBlank() }
            saveConnection()
        } else {
            serverIp = connectionPreferences.getString("server_ip", "") ?: ""
            serverPort = connectionPreferences.getInt("server_port", 8080)
            serverFingerprint = connectionPreferences.getString("server_fingerprint", "") ?: ""
            serverName = connectionPreferences.getString("server_name", "Saved Mac") ?: "Saved Mac"
            pairingCode = null
        }
        if (serverFingerprint.length != 64) {
            Log.e(TAG, "No saved secure desktop connection to restore")
            stopSelf()
            return START_NOT_STICKY
        }
        client = createPinnedClient(serverFingerprint)
        pairingStore = PairingStore(this)
        pairingSecret = pairingStore.secret(serverFingerprint)
        syncAuthenticated = false

        // Reset reconnect flag when service starts
        shouldReconnect = true
        handler.removeCallbacks(pairingTimeout)
        if (pairingCode != null) {
            handler.postDelayed(pairingTimeout, 20_000)
        }
        publishStatus(
            if (pairingCode == null && pairingSecret != null) "connecting" else "pairing",
            if (pairingCode == null && pairingSecret != null)
                "Connecting with saved pairing..."
            else
                "Waiting for Mac to accept the pairing code...",
        )

        // Start foreground with notification
        startForeground(NOTIFICATION_ID, createNotification())

        // Initialize clipboard manager
        if (clipboardManager == null) {
            clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        }

        // Connect to desktop server
        if (webSocket == null) {
            connectToServer()
        }

        // Start clipboard listener
        if (clipboardListener == null) {
            startClipboardListener()
        }

        // Android may recreate this service after an ordinary memory/process
        // kill. The saved connection data then restores secure sync.
        return START_STICKY
    }

    private fun createNotification(): Notification {
        // Create notification channel for Android 8+
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Clipboard Sync",
                NotificationManager.IMPORTANCE_LOW
            )
            val manager = getSystemService(NotificationManager::class.java)
            manager?.createNotificationChannel(channel)
        }

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Clipboard Sync Active")
            .setContentText("Securely syncing with desktop at $serverIp:$serverPort")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .build()
    }

    private fun saveConnection() {
        connectionPreferences.edit()
            .putString("server_ip", serverIp)
            .putInt("server_port", serverPort)
            .putString("server_fingerprint", serverFingerprint)
            .putString("server_name", serverName)
            .apply()
    }

    private fun clearSavedConnection() {
        connectionPreferences.edit().clear().apply()
    }

    private fun clearImageTransferState() {
        imageOfferExpiry?.let(handler::removeCallbacks)
        imageOfferExpiry = null
        pendingImageOffers.clear()
        incomingImages.clear()
        clearStoredImageOffer()
        outgoingImageTimers.values.forEach(handler::removeCallbacks)
        outgoingImageTimers.clear()
        outgoingImages.clear()
    }

    private fun clearStoredImageOffer() {
        // Keep ui_active: it describes whether MainActivity is visible, not
        // whether an image is currently waiting for a decision.
        imageOfferPreferences.edit()
            .remove("id")
            .remove("name")
            .remove("mime")
            .remove("size")
            .apply()
    }

    private fun publishStatus(state: String, message: String) {
        connectionPreferences.edit()
            .putString("sync_state", state)
            .putString("sync_message", message)
            .apply()
    }

    private fun connectToServer() {
        // Close existing WebSocket before creating new one
        webSocket?.close(1000, "Reconnecting")
        webSocket = null

        val url = "wss://$serverIp:$serverPort"
        val request = Request.Builder().url(url).build()

        val listener = object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                Log.i(TAG, "Connected to desktop at $url")
                this@ClipboardService.webSocket = webSocket
                reconnectDelay = 1000L // Reset delay on successful connection
                publishStatus("authenticating", "Verifying secure pairing...")
                beginAuthentication(webSocket)
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                handler.post {
                    handleSecureMessage(webSocket, text)
                }
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                Log.w(TAG, "Connection closed: $reason")
                this@ClipboardService.webSocket = null
                clearImageTransferState()
                if (shouldReconnect) {  // Only reconnect if flag is true
                    publishStatus("reconnecting", "Connection lost. Reconnecting...")
                    reconnect()
                }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                Log.e(TAG, "Connection failed: ${t.message}")
                this@ClipboardService.webSocket = null
                clearImageTransferState()
                if (shouldReconnect) {  // Only reconnect if flag is true
                    publishStatus("reconnecting", "Could not reach Mac. Reconnecting...")
                    reconnect()
                }
            }
        }

        webSocket = client?.newWebSocket(request, listener)
    }

    private fun beginAuthentication(webSocket: WebSocket) {
        val secret = pairingSecret
        // A newly entered code intentionally replaces any older saved pairing.
        // Check it first; otherwise an existing secret would silently win and
        // the code shown in the Android UI would never be sent.
        if (pairingCode != null) {
            publishStatus("pairing", "Checking pairing code...")
            Log.i(TAG, "Sending pair request to Mac")
            webSocket.send(JSONObject()
                .put("type", "pairRequest")
                .put("deviceId", pairingStore.deviceId())
                .put("pairCode", pairingCode)
                .toString())
        } else if (secret != null) {
            webSocket.send(JSONObject()
                .put("type", "hello")
                .put("deviceId", pairingStore.deviceId())
                .toString())
        } else {
            Log.e(TAG, "This Mac is not paired. Enter its pairing code first.")
            shouldReconnect = false
            publishStatus("pairingRequired", "This Mac needs a pairing code.")
            webSocket.close(1008, "Pairing required")
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    private fun handleSecureMessage(webSocket: WebSocket, text: String) {
        val message = try { JSONObject(text) } catch (_: Exception) {
            webSocket.close(1002, "Invalid secure protocol")
            return
        }
        when (message.optString("type")) {
            "pairAccepted" -> {
                Log.i(TAG, "Mac accepted pairing code")
                pairingSecret = message.getString("pairingSecret")
                pairingStore.saveSecret(serverFingerprint, pairingSecret!!)
                pairingStore.saveDeviceName(serverFingerprint, serverName)
                // The single-use code has completed its job. From here onward
                // authenticate with the saved secret, not by sending the code
                // to the Mac a second time.
                pairingCode = null
                publishStatus("authenticating", "Pairing saved. Verifying secure connection...")
                beginAuthentication(webSocket)
            }
            "challenge" -> {
                Log.i(TAG, "Mac requested pairing proof")
                val secret = pairingSecret ?: return
                val proof = hmac(secret, message.getString("value"))
                webSocket.send(JSONObject().put("type", "authenticate").put("proof", proof).toString())
            }
            "syncAccepted" -> {
                syncAuthenticated = true
                handler.removeCallbacks(pairingTimeout)
                publishStatus("connected", "Securely connected to $serverName")
                Log.i(TAG, "Secure pairing authenticated")
            }
            "clipboardUpdate" -> {
                if (!syncAuthenticated) return
                writeToClipboard(message.optString("text"))
            }
            "imageOffer" -> {
                if (!syncAuthenticated) return
                val id = message.getString("id")
                if (!imageOfferPreferences.getBoolean("ui_active", false)) {
                    Log.i(TAG, "Image offer rejected because Clipboard Sync is not open")
                    webSocket.send(
                        JSONObject()
                            .put("type", "imageReject")
                            .put("id", id)
                            .put("reason", "Clipboard Sync is not open on Android")
                            .toString()
                    )
                    return
                }
                pendingImageOffers.keys.toList().forEach { previousId ->
                    webSocket.send(JSONObject().put("type", "imageReject").put("id", previousId).toString())
                }
                cancelOutgoingImageOffers(
                    "A Mac image offer replaced this Android image offer"
                )
                clearImageTransferState()
                val offer = ImageOffer(
                    id,
                    message.getString("name"),
                    message.getString("mime"),
                    message.getLong("size"),
                    message.getString("sha256")
                )
                pendingImageOffers[offer.id] = offer
                showImageOffer(offer)
            }
            "imageStart" -> {
                val id = message.getString("id")
                if (pendingImageOffers.containsKey(id)) {
                    incomingImages[id] = ByteArrayOutputStream()
                }
            }
            "imageChunk" -> {
                val id = message.getString("id")
                val chunk = android.util.Base64.decode(
                    message.getString("data"),
                    android.util.Base64.NO_WRAP
                )
                val stream = incomingImages[id]
                if (stream != null) {
                    if (stream.size() + chunk.size > IMAGE_LIMIT_BYTES) {
                        rejectImage(id, "Image exceeded the 20 MB transfer limit")
                    } else {
                        stream.write(chunk)
                    }
                }
            }
            "imageEnd" -> {
                finishImage(message.getString("id"))
            }
            "imageAccept" -> {
                if (syncAuthenticated) {
                    sendOutgoingImage(message.getString("id"))
                }
            }
            "imageReject" -> {
                val id = message.getString("id")
                if (outgoingImages.containsKey(id)) {
                    clearOutgoingImage(id)
                    Log.i(
                        TAG,
                        "Mac declined Android image: ${message.optString("reason", "ignored")}"
                    )
                }
            }
            "error" -> {
                val error = message.optString("message")
                Log.e(TAG, "Secure sync error: $error")
                shouldReconnect = false
                handler.removeCallbacks(pairingTimeout)
                publishStatus("error", error.ifBlank { "Secure connection failed." })
                webSocket.close(1008, "Authentication error")
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
    }

    private fun showImageOffer(offer: ImageOffer) {
        imageOfferExpiry?.let(handler::removeCallbacks)
        imageOfferPreferences.edit()
            .putString("id", offer.id)
            .putString("name", offer.name)
            .putString("mime", offer.mime)
            .putLong("size", offer.size)
            .apply()
        imageOfferExpiry = Runnable {
            if (pendingImageOffers.containsKey(offer.id)) {
                Log.i(TAG, "Image offer expired after 2 minutes: ${offer.name}")
                rejectImage(offer.id, "Image offer expired after 2 minutes")
            }
        }.also { handler.postDelayed(it, 2 * 60 * 1000L) }
        Log.i(TAG, "Image offer saved for in-app approval: ${offer.name}")
    }

    private fun acceptImage(id: String) {
        if (!pendingImageOffers.containsKey(id)) return
        imageOfferExpiry?.let(handler::removeCallbacks)
        imageOfferExpiry = null
        clearStoredImageOffer()
        webSocket?.send(JSONObject().put("type", "imageAccept").put("id", id).toString())
    }

    private fun rejectImage(id: String, reason: String? = null) {
        if (!pendingImageOffers.containsKey(id)) return
        imageOfferExpiry?.let(handler::removeCallbacks)
        imageOfferExpiry = null
        clearStoredImageOffer()
        pendingImageOffers.remove(id)
        incomingImages.remove(id)
        val message = JSONObject().put("type", "imageReject").put("id", id)
        if (reason != null) message.put("reason", reason)
        webSocket?.send(message.toString())
    }

    private fun finishImage(id: String) {
        val offer = pendingImageOffers.remove(id) ?: return
        imageOfferExpiry?.let(handler::removeCallbacks)
        imageOfferExpiry = null
        val bytes = incomingImages.remove(id)?.toByteArray() ?: return
        val hash = MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it) }
        if (hash != offer.sha256) {
            Log.e(TAG, "Image hash did not match")
            return
        }
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, offer.name)
            put(MediaStore.Images.Media.MIME_TYPE, offer.mime)
            put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/Clipboard Sync")
        }
        val uri = contentResolver.insert(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            values
        ) ?: return
        contentResolver.openOutputStream(uri)?.use { it.write(bytes) } ?: return
        lastReceivedImageUri = uri.toString()
        clipboardManager?.setPrimaryClip(ClipData.newUri(contentResolver, offer.name, uri))
        Log.i(TAG, "Received image saved and placed on clipboard: $uri")
    }

    private fun offerClipboardImage(clipData: ClipData) {
        if (!syncAuthenticated ||
            !imageOfferPreferences.getBoolean("ui_active", false)) {
            return
        }
        val item = clipData.getItemAt(0)
        val uri = item.uri ?: return
        if (uri.toString() == lastReceivedImageUri) {
            lastReceivedImageUri = null
            return
        }
        val mime = clipboardImageMime(clipData, uri) ?: return
        val bytes = readImageBytes(uri) ?: return
        if (bytes.size > IMAGE_LIMIT_BYTES) {
            Log.w(TAG, "Android image is still over 20 MB after compression")
            return
        }
        cancelOutgoingImageOffers("A newer Android image replaced this offer")
        val normalizedMime = when (mime.lowercase()) {
            "image/png" -> "image/png"
            "image/jpeg", "image/jpg" -> "image/jpeg"
            "image/webp" -> "image/webp"
            else -> "image/jpeg"
        }
        val extension = when (normalizedMime) {
            "image/png" -> "png"
            "image/webp" -> "webp"
            else -> "jpg"
        }
        val id = randomImageId()
        val image = OutgoingImage(
            bytes = bytes,
            name = "android-clipboard-image.$extension",
            mime = normalizedMime
        )
        outgoingImages[id] = image
        val timer = Runnable {
            if (outgoingImages.containsKey(id)) {
                clearOutgoingImage(id)
                webSocket?.send(
                    JSONObject()
                        .put("type", "imageReject")
                        .put("id", id)
                        .put("reason", "Android image offer expired after 2 minutes")
                        .toString()
                )
                Log.i(TAG, "Android image offer expired after 2 minutes")
            }
        }
        outgoingImageTimers[id] = timer
        handler.postDelayed(timer, 2 * 60 * 1000L)
        webSocket?.send(
            JSONObject()
                .put("type", "imageOffer")
                .put("id", id)
                .put("name", image.name)
                .put("mime", image.mime)
                .put("size", image.bytes.size)
                .put("sha256", sha256(image.bytes))
                .toString()
        )
        Log.i(TAG, "Android image offer sent to Mac: ${image.bytes.size} bytes")
        publishStatus(
            "connected",
            "Image copied. On your Mac, choose Receive or Ignore within 2 minutes."
        )
    }

    private fun clipboardImageMime(
        clipData: ClipData,
        uri: android.net.Uri
    ): String? {
        val resolverMime = contentResolver.getType(uri)
        if (resolverMime?.startsWith("image/") == true) return resolverMime
        return clipData.description
            .filterMimeTypes("image/*")
            ?.firstOrNull()
    }

    private fun isClipboardImage(clipData: ClipData): Boolean {
        val uri = clipData.getItemAt(0).uri ?: return false
        return clipboardImageMime(clipData, uri) != null
    }

    private fun readImageBytes(uri: android.net.Uri): ByteArray? {
        val limited = ByteArrayOutputStream()
        contentResolver.openInputStream(uri)?.use { input ->
            val buffer = ByteArray(32 * 1024)
            while (limited.size() <= IMAGE_LIMIT_BYTES) {
                val count = input.read(buffer)
                if (count <= 0) break
                limited.write(buffer, 0, count)
            }
        } ?: return null
        if (limited.size() <= IMAGE_LIMIT_BYTES) {
            return limited.toByteArray()
        }
        val bitmap = contentResolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it)
        } ?: return null
        return try {
            ByteArrayOutputStream().use { compressed ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, 80, compressed)
                compressed.toByteArray().takeIf { it.size <= IMAGE_LIMIT_BYTES }
            }
        } finally {
            bitmap.recycle()
        }
    }

    private fun sendOutgoingImage(id: String) {
        val image = outgoingImages[id] ?: return
        clearOutgoingImage(id)
        val socket = webSocket ?: return
        socket.send(
            JSONObject()
                .put("type", "imageStart")
                .put("id", id)
                .put("name", image.name)
                .put("mime", image.mime)
                .put("size", image.bytes.size)
                .put("sha256", sha256(image.bytes))
                .toString()
        )
        val chunkSize = 48 * 1024
        var offset = 0
        while (offset < image.bytes.size) {
            val end = minOf(offset + chunkSize, image.bytes.size)
            socket.send(
                JSONObject()
                    .put("type", "imageChunk")
                    .put("id", id)
                    .put(
                        "data",
                        android.util.Base64.encodeToString(
                            image.bytes.copyOfRange(offset, end),
                            android.util.Base64.NO_WRAP
                        )
                    )
                    .toString()
            )
            offset = end
        }
        socket.send(JSONObject().put("type", "imageEnd").put("id", id).toString())
        Log.i(TAG, "Android image sent to Mac")
    }

    private fun clearOutgoingImage(id: String) {
        outgoingImageTimers.remove(id)?.let(handler::removeCallbacks)
        outgoingImages.remove(id)
    }

    private fun cancelOutgoingImageOffers(reason: String) {
        outgoingImages.keys.toList().forEach { id ->
            webSocket?.send(
                JSONObject()
                    .put("type", "imageReject")
                    .put("id", id)
                    .put("reason", reason)
                    .toString()
            )
            clearOutgoingImage(id)
        }
    }

    private fun cancelAllImageTransfers(reason: String) {
        pendingImageOffers.keys.toList().forEach { id -> rejectImage(id, reason) }
        cancelOutgoingImageOffers(reason)
    }

    private fun randomImageId(): String {
        val bytes = ByteArray(24)
        SecureRandom().nextBytes(bytes)
        return android.util.Base64.encodeToString(
            bytes,
            android.util.Base64.URL_SAFE or android.util.Base64.NO_WRAP or android.util.Base64.NO_PADDING
        )
    }

    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it) }

    private fun hmac(secret: String, challenge: String): String {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(secret.toByteArray(), "HmacSHA256"))
        return mac.doFinal(challenge.toByteArray()).joinToString("") { "%02x".format(it) }
    }

    private fun normalizeFingerprint(value: String): String {
        return value.replace(":", "").replace(Regex("\\s"), "").uppercase()
    }

    private fun createPinnedClient(expectedFingerprint: String): OkHttpClient {
        val trustManager = object : X509TrustManager {
            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()

            override fun checkClientTrusted(
                chain: Array<X509Certificate>,
                authType: String
            ) {
                throw CertificateException("Client certificates are not supported")
            }

            override fun checkServerTrusted(
                chain: Array<X509Certificate>,
                authType: String
            ) {
                if (chain.isEmpty()) {
                    throw CertificateException("Desktop did not provide a certificate")
                }
                val actual = MessageDigest.getInstance("SHA-256")
                    .digest(chain[0].encoded)
                    .joinToString("") { "%02X".format(it) }
                if (actual != expectedFingerprint) {
                    throw CertificateException("Desktop certificate fingerprint does not match")
                }
            }
        }
        val context = SSLContext.getInstance("TLS")
        context.init(null, arrayOf<TrustManager>(trustManager), SecureRandom())

        return OkHttpClient.Builder()
            .sslSocketFactory(context.socketFactory, trustManager)
            // The desktop certificate is self-signed and has no stable LAN hostname.
            // The strict certificate fingerprint check above is the identity check.
            .hostnameVerifier(HostnameVerifier { _, _ -> true })
            .build()
    }

    private fun reconnect() {
        handler.postDelayed({
            Log.i(TAG, "Reconnecting in ${reconnectDelay}ms...")
            publishStatus("reconnecting", "Reconnecting to $serverName...")
            connectToServer()
            reconnectDelay = (reconnectDelay * 2).coerceAtMost(maxDelay)
        }, reconnectDelay)
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.w(TAG, "Foreground service time limit reached; stopping sync safely")
        shouldReconnect = false
        handler.removeCallbacksAndMessages(null)
        webSocket?.close(1000, "Foreground service timeout")
        webSocket = null
        publishStatus("stopped", "Sync stopped by Android.")
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun startClipboardListener() {
        clipboardListener = ClipboardManager.OnPrimaryClipChangedListener {
            val clipData = clipboardManager?.primaryClip
            if (clipData != null && clipData.itemCount > 0) {
                val description = clipboardManager?.primaryClipDescription
                if (isClipboardImage(clipData)) {
                    offerClipboardImage(clipData)
                    return@OnPrimaryClipChangedListener
                }
                val text = stripAllLatencyPrefixes(
                    clipData.getItemAt(0).text?.toString() ?: ""
                )

                if (text.startsWith("CS1|")) {
                    return@OnPrimaryClipChangedListener
                }

                if (syncAuthenticated && text.isNotEmpty() && text != lastClipboardText) {
                    lastClipboardText = text
                    Log.i(TAG, "Clipboard changed: $text")
                    val sendStart = SystemClock.elapsedRealtime()
                    webSocket?.send(
                        JSONObject()
                            .put("type", "clipboardUpdate")
                            .put("text", text)
                            .put("sentAt", System.currentTimeMillis())
                            .toString()
                    )
                    val sendMs = SystemClock.elapsedRealtime() - sendStart
                    Log.i(TAG, "LATENCY Android→Mac local_send=${sendMs}ms text=\"$text\"")
                }
            }
        }

        clipboardManager?.addPrimaryClipChangedListener(clipboardListener)
    }

    private fun writeToClipboard(text: String) {
        if (text == lastClipboardText) return

        try {
            val clip = ClipData.newPlainText("clipboard_sync", text)
            clipboardManager?.setPrimaryClip(clip)
            lastClipboardText = text // Update to prevent loop
        } catch (e: Exception) {
            Log.e(TAG, "Failed to write to clipboard: ${e.message}")
        }
    }

    override fun onDestroy() {
        super.onDestroy()

        // Stop reconnection attempts
        shouldReconnect = false

        // Cancel any pending reconnect callbacks
        handler.removeCallbacksAndMessages(null)
        handler.removeCallbacks(pairingTimeout)

        // Clean up clipboard listener
        clipboardListener?.let {
            clipboardManager?.removePrimaryClipChangedListener(it)
        }

        // Close WebSocket
        webSocket?.close(1000, "Service stopped")
        webSocket = null
        clearImageTransferState()
        client?.dispatcher?.executorService?.shutdown()
        client = null
        if (!shouldReconnect && !syncAuthenticated) {
            publishStatus("stopped", "Sync is stopped")
        }

        Log.i(TAG, "Service stopped and reconnection disabled")
    }

    override fun onBind(intent: Intent?): IBinder? {
        return null
    }
}
