package com.example.android_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Intent
import android.os.Build
import android.app.ActivityManager
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
                    startClipboardService(ip, port)
                    result.success("Service started")
                }
                "stopService" -> {
                    stopClipboardService()
                    result.success("Service stopped")
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    private fun startClipboardService(ip: String?, port: Int) {
        val intent = Intent(this, ClipboardService::class.java)
        intent.putExtra("SERVER_IP", ip)
        intent.putExtra("SERVER_PORT", port)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun stopClipboardService() {
        val intent = Intent(this, ClipboardService::class.java).apply {
            action = "STOP"
        }
        startService(intent)   // Delivers STOP to onStartCommand
        stopService(intent)    // Also ask system to tear it down
    }
}
