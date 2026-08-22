package com.xymusic.mobile

import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Build
import androidx.core.content.ContextCompat
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    companion object {
        private const val CHANNEL = "com.xymusic.mobile/system_audio_capture"
        private const val EVENTS = "com.xymusic.mobile/system_audio_capture/events"
        private const val DEVICE_INFO_CHANNEL = "com.xymusic.mobile/device_info"
        private const val CAPTURE_REQUEST = 4217
    }

    private var pendingStartResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_INFO_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "getDeviceInfo") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val versionName = try {
                    packageManager.getPackageInfo(packageName, 0).versionName ?: ""
                } catch (_: Exception) {
                    ""
                }
                result.success(
                    mapOf(
                        "manufacturer" to Build.MANUFACTURER,
                        "model" to Build.MODEL,
                        "osVersion" to Build.VERSION.RELEASE,
                        "sdkInt" to Build.VERSION.SDK_INT,
                        "appVersion" to versionName,
                    ),
                )
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isSupported" -> result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                    "start" -> requestSystemAudioCapture(result)
                    "stop" -> {
                        stopService(Intent(this, SystemAudioCaptureService::class.java))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENTS)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    SystemAudioCaptureBridge.eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    SystemAudioCaptureBridge.eventSink = null
                }
            })
    }

    private fun requestSystemAudioCapture(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error("UNSUPPORTED", "系统声音识别需要 Android 10 或更高版本", null)
            return
        }
        if (pendingStartResult != null) {
            result.error("BUSY", "系统声音授权正在进行", null)
            return
        }
        pendingStartResult = result
        val manager = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        startActivityForResult(manager.createScreenCaptureIntent(), CAPTURE_REQUEST)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != CAPTURE_REQUEST) return
        val result = pendingStartResult
        pendingStartResult = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            result?.success(false)
            return
        }
        val serviceIntent = Intent(this, SystemAudioCaptureService::class.java).apply {
            action = SystemAudioCaptureService.ACTION_START
            putExtra(SystemAudioCaptureService.EXTRA_RESULT_CODE, resultCode)
            putExtra(SystemAudioCaptureService.EXTRA_RESULT_DATA, data)
        }
        ContextCompat.startForegroundService(this, serviceIntent)
        result?.success(true)
    }
}
