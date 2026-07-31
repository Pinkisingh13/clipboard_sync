package com.example.android_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener

class ClipboardService : Service() {

    companion object {
        private const val TAG = "ClipboardService"
        private const val CHANNEL_ID = "clipboard_sync_channel"
        private const val NOTIFICATION_ID = 1
    }

    private var webSocket: WebSocket? = null
    private val client = OkHttpClient()
    private var clipboardManager: ClipboardManager? = null
    private var clipboardListener: ClipboardManager.OnPrimaryClipChangedListener? = null
    private var lastClipboardText = ""
    private var serverIp = ""
    private var serverPort = 8080
    private var reconnectDelay = 1000L
    private val maxDelay = 32000L
    private val handler = Handler(Looper.getMainLooper())

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Get server IP and port from Intent
        serverIp = intent?.getStringExtra("SERVER_IP") ?: "192.168.1.5"
        serverPort = intent?.getIntExtra("SERVER_PORT", 8080) ?: 8080

        // Start foreground with notification
        startForeground(NOTIFICATION_ID, createNotification())

        // Initialize clipboard manager
        if (clipboardManager == null) {
            clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        }

        // Connect to Mac server
        if (webSocket == null) {
            connectToServer()
        }

        // Start clipboard listener
        if (clipboardListener == null) {
            startClipboardListener()
        }

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
            .setContentText("Connected to Mac at $serverIp:$serverPort")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .build()
    }

    private fun connectToServer() {
        val url = "ws://$serverIp:$serverPort"
        val request = Request.Builder().url(url).build()

        val listener = object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                Log.i(TAG, "✅ Connected to Mac at $url")
                this@ClipboardService.webSocket = webSocket
                reconnectDelay = 1000L // Reset delay on successful connection
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                Log.i(TAG, "📋 Received from Mac: $text")
                handler.post { writeToClipboard(text) }
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                Log.w(TAG, "❌ Connection closed: $reason")
                this@ClipboardService.webSocket = null
                reconnect()
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                Log.e(TAG, "⚠️ Connection failed: ${t.message}")
                this@ClipboardService.webSocket = null
                reconnect()
            }
        }

        webSocket = client.newWebSocket(request, listener)
    }

    private fun reconnect() {
        handler.postDelayed({
            Log.i(TAG, "🔄 Reconnecting in ${reconnectDelay}ms...")
            connectToServer()
            reconnectDelay = (reconnectDelay * 2).coerceAtMost(maxDelay)
        }, reconnectDelay)
    }

    private fun startClipboardListener() {
        clipboardListener = ClipboardManager.OnPrimaryClipChangedListener {
            val clipData = clipboardManager?.primaryClip
            if (clipData != null && clipData.itemCount > 0) {
                val text = clipData.getItemAt(0).text?.toString() ?: ""

                if (text.isNotEmpty() && text != lastClipboardText) {
                    lastClipboardText = text
                    Log.i(TAG, "📱 Clipboard changed: $text")
                    webSocket?.send(text)
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

        // Clean up
        clipboardListener?.let {
            clipboardManager?.removePrimaryClipChangedListener(it)
        }

        webSocket?.close(1000, "Service stopped")
        webSocket = null
        handler.removeCallbacksAndMessages(null)

        Log.i(TAG, "🛑 Service stopped")
    }

    override fun onBind(intent: Intent?): IBinder? {
        return null
    }
}
