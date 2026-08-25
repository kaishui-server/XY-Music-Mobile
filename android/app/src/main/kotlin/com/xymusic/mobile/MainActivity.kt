package com.xymusic.mobile

import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.view.WindowManager
import androidx.core.content.FileProvider
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
        private const val APP_UPDATE_CHANNEL = "com.xymusic.mobile/app_update"
        private const val DESKTOP_LYRICS_CHANNEL = "com.xymusic.mobile/desktop_lyrics"
        private const val SCREEN_AWAKE_CHANNEL = "com.xymusic.mobile/screen_awake"
        private const val CAPTURE_REQUEST = 4217
    }

    private var pendingStartResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SCREEN_AWAKE_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "setKeepScreenOn") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val enabled = call.argument<Boolean>("enabled") == true
                runOnUiThread {
                    if (enabled) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(true)
                }
            }
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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APP_UPDATE_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "installApk") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val path = call.argument<String>("path")?.trim().orEmpty()
                if (path.isEmpty()) {
                    result.error("INVALID_PATH", "安装包路径为空", null)
                    return@setMethodCallHandler
                }
                try {
                    val file = java.io.File(path)
                    if (!file.exists() || file.length() <= 0L) {
                        result.error("FILE_NOT_FOUND", "安装包文件不存在或为空", null)
                        return@setMethodCallHandler
                    }
                    val uri: Uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                        FileProvider.getUriForFile(this, "${packageName}.fileprovider", file)
                    } else {
                        Uri.fromFile(file)
                    }
                    val intent = Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(uri, "application/vnd.android.package-archive")
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    startActivity(intent)
                    result.success(true)
                } catch (error: Exception) {
                    result.error("INSTALL_FAILED", error.message ?: "无法打开安装程序", null)
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DESKTOP_LYRICS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setEnabled" -> {
                        val enabled = call.argument<Boolean>("enabled") == true
                        if (!enabled) {
                            stopService(Intent(this, DesktopLyricsService::class.java))
                            result.success(true)
                            return@setMethodCallHandler
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
                            !Settings.canDrawOverlays(this)
                        ) {
                            startActivity(
                                Intent(
                                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                    Uri.parse("package:$packageName"),
                                ),
                            )
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        try {
                            // 从前台 Activity 启动普通服务，避免未创建通知频道时触发
                            // Android 8+ 的 ForegroundServiceDidNotStartInTimeException。
                            startService(
                                Intent(this, DesktopLyricsService::class.java).apply {
                                    action = DesktopLyricsService.ACTION_SHOW
                                },
                            )
                            result.success(true)
                        } catch (_: Exception) {
                            result.success(false)
                        }
                    }
                    "update" -> {
                        try {
                            startService(
                                Intent(this, DesktopLyricsService::class.java).apply {
                                    action = DesktopLyricsService.ACTION_UPDATE
                                    putExtra("title", call.argument<String>("title") ?: "")
                                    putExtra("artist", call.argument<String>("artist") ?: "")
                                    putExtra("lyric", call.argument<String>("lyric") ?: "")
                                    putExtra("translation", call.argument<String>("translation") ?: "")
                                    putExtra("wordsJson", call.argument<String>("wordsJson") ?: "[]")
                                    putExtra("position", call.argument<Number>("position")?.toDouble() ?: 0.0)
                                    putExtra("wordEffectMode", call.argument<Number>("wordEffectMode")?.toInt() ?: 2)
                                    putExtra("locked", call.argument<Boolean>("locked") == true)
                                    putExtra("noBackground", call.argument<Boolean>("noBackground") != false)
                                    putExtra("lyricColor", call.argument<Number>("lyricColor")?.toInt() ?: 0xFFFFFFFF.toInt())
                                    putExtra("translationColor", call.argument<Number>("translationColor")?.toInt() ?: 0xFFE1E1E6.toInt())
                                    putExtra("lyricFontSize", call.argument<Number>("lyricFontSize")?.toFloat() ?: 24f)
                                    putExtra("translationFontSize", call.argument<Number>("translationFontSize")?.toFloat() ?: 13f)
                                    putExtra("backgroundColor", call.argument<Number>("backgroundColor")?.toInt() ?: 0xFF18181C.toInt())
                                    putExtra("backgroundOpacity", (call.argument<Number>("backgroundOpacity")?.toFloat() ?: .85f))
                                },
                            )
                            result.success(true)
                        } catch (_: Exception) {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
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
