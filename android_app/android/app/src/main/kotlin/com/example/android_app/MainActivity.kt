package com.example.android_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Intent
import android.os.Build
import android.content.Context

class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "clipboard_sync"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startService" -> {
                    val ip = call.argument<String>("serverIp")
                    val port = call.argument<Int>("serverPort") ?: 8080
                    val fingerprint = call.argument<String>("serverFingerprint")
                    val pairingCode = call.argument<String>("pairingCode")
                    val serverName = call.argument<String>("serverName")
                    startClipboardService(ip, port, fingerprint, pairingCode, serverName)
                    result.success("Service started")
                }
                "stopService" -> {
                    stopClipboardService()
                    result.success("Service stopped")
                }
                "forgetPairing" -> {
                    val fingerprint = call.argument<String>("serverFingerprint")
                    if (fingerprint.isNullOrBlank()) {
                        result.error("bad_args", "A server fingerprint is required", null)
                    } else {
                        PairingStore(this).forget(
                            fingerprint.replace(":", "").replace(Regex("\\s"), "").uppercase()
                        )
                        stopClipboardService()
                        result.success("Saved pairing removed")
                    }
                }
                "hasPairing" -> {
                    val fingerprint = call.argument<String>("serverFingerprint")
                    if (fingerprint.isNullOrBlank()) {
                        result.success(false)
                    } else {
                        val normalized = fingerprint
                            .replace(":", "")
                            .replace(Regex("\\s"), "")
                            .uppercase()
                        result.success(PairingStore(this).secret(normalized) != null)
                    }
                }
                "listPairedDevices" -> {
                    result.success(
                        PairingStore(this).pairedDevices().map { device ->
                            mapOf(
                                "fingerprint" to device.fingerprint,
                                "name" to device.name,
                            )
                        }
                    )
                }
                "getSyncStatus" -> {
                    val preferences = getSharedPreferences(
                        "clipboard_sync_connection",
                        Context.MODE_PRIVATE
                    )
                    result.success(
                        mapOf(
                            "state" to (preferences.getString("sync_state", "stopped") ?: "stopped"),
                            "message" to (preferences.getString("sync_message", "Sync is stopped")
                                ?: "Sync is stopped"),
                        )
                    )
                }
                "getPendingImageOffer" -> {
                    val prefs = getSharedPreferences("clipboard_sync_image_offer", Context.MODE_PRIVATE)
                    if (!prefs.contains("id")) {
                        result.success(null)
                    } else {
                        result.success(mapOf(
                            "id" to prefs.getString("id", ""),
                            "name" to prefs.getString("name", "image"),
                            "mime" to prefs.getString("mime", "image/png"),
                            "size" to prefs.getLong("size", 0L),
                        ))
                    }
                }
                "respondToImageOffer" -> {
                    val id = call.argument<String>("id")
                    val accept = call.argument<Boolean>("accept") == true
                    if (id.isNullOrBlank()) {
                        result.error("bad_args", "Image offer id is required", null)
                    } else {
                        respondToImageOffer(id, accept)
                        result.success(true)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        imageOfferPreferences().edit().putBoolean("ui_active", true).apply()
        checkClipboardImageAfterResume()
    }

    override fun onPause() {
        imageOfferPreferences().edit().putBoolean("ui_active", false).apply()
        cancelIncomingImageOffers("Clipboard Sync is not open on Android")
        super.onPause()
    }

    private fun startClipboardService(
        ip: String?,
        port: Int,
        fingerprint: String?,
        pairingCode: String?,
        serverName: String?
    ) {
        val intent = Intent(this, ClipboardService::class.java)
        intent.putExtra("SERVER_IP", ip)
        intent.putExtra("SERVER_PORT", port)
        intent.putExtra("SERVER_FINGERPRINT", fingerprint)
        intent.putExtra("PAIRING_CODE", pairingCode)
        intent.putExtra("SERVER_NAME", serverName)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun respondToImageOffer(id: String, accept: Boolean) {
        val intent = Intent(this, ClipboardService::class.java).apply {
            action = if (accept) ClipboardService.ACTION_ACCEPT_IMAGE
            else ClipboardService.ACTION_REJECT_IMAGE
            putExtra("IMAGE_ID", id)
        }
        // An offer can exist only while the foreground sync service already
        // exists. Deliver the answer to that service without trying to start a
        // new foreground service while this Activity is leaving the screen.
        startService(intent)
    }

    private fun imageOfferPreferences() =
        getSharedPreferences("clipboard_sync_image_offer", Context.MODE_PRIVATE)

    private fun cancelIncomingImageOffers(reason: String) {
        startService(Intent(this, ClipboardService::class.java).apply {
            action = ClipboardService.ACTION_CANCEL_INCOMING_IMAGE_OFFERS
            putExtra("REASON", reason)
        })
    }

    private fun checkClipboardImageAfterResume() {
        val state = getSharedPreferences(
            "clipboard_sync_connection",
            Context.MODE_PRIVATE
        ).getString("sync_state", "stopped")
        if (state != "connected") return
        startService(Intent(this, ClipboardService::class.java).apply {
            action = ClipboardService.ACTION_CHECK_CLIPBOARD_IMAGE
        })
    }

    private fun stopClipboardService() {
        val intent = Intent(this, ClipboardService::class.java).apply {
            action = "STOP"
        }
        startService(intent)   // Delivers STOP to onStartCommand
        stopService(intent)    // Also ask system to tear it down
    }
}
