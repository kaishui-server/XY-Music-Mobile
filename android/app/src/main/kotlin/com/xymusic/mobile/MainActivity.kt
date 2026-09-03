package com.xymusic.mobile

import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.DocumentsContract
import android.provider.Settings
import android.view.WindowManager
import android.media.MediaScannerConnection
import java.io.File
import java.io.FileOutputStream
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
        private const val GALLERY_CHANNEL = "com.xymusic.mobile/gallery"
        private const val STORAGE_CHANNEL = "com.xymusic.mobile/storage"
        private const val CAPTURE_REQUEST = 4217
        private const val DIRECTORY_REQUEST = 4218
    }

    private var pendingStartResult: MethodChannel.Result? = null
    private var pendingDirectoryResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        // 尽早安装，捕获进程内所有线程的未捕获异常并写入崩溃文件。
        CrashHandler.install(this)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        StoragePermissionBridge.register(this, flutterEngine)
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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, GALLERY_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "saveImage") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val bytes = call.argument<ByteArray>("bytes")
                val fileName = call.argument<String>("fileName")?.trim().orEmpty()
                    .ifEmpty { "xy_music_share_${System.currentTimeMillis()}.png" }
                if (bytes == null || bytes.isEmpty()) {
                    result.error("INVALID_IMAGE", "图片数据为空", null)
                    return@setMethodCallHandler
                }
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        val values = ContentValues().apply {
                            put(MediaStore.Images.Media.DISPLAY_NAME, fileName)
                            put(MediaStore.Images.Media.MIME_TYPE, "image/png")
                            put(
                                MediaStore.Images.Media.RELATIVE_PATH,
                                Environment.DIRECTORY_PICTURES + "/XY Music",
                            )
                            put(MediaStore.Images.Media.IS_PENDING, 1)
                        }
                        val uri = contentResolver.insert(
                            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                            values,
                        ) ?: throw IllegalStateException("无法创建相册文件")
                        try {
                            contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                                ?: throw IllegalStateException("无法写入相册文件")
                            values.clear()
                            values.put(MediaStore.Images.Media.IS_PENDING, 0)
                            contentResolver.update(uri, values, null, null)
                        } catch (error: Exception) {
                            contentResolver.delete(uri, null, null)
                            throw error
                        }
                    } else {
                        val pictures = Environment.getExternalStoragePublicDirectory(
                            Environment.DIRECTORY_PICTURES,
                        )
                        val directory = File(pictures, "XY Music")
                        if (!directory.exists() && !directory.mkdirs()) {
                            throw IllegalStateException("无法创建相册目录")
                        }
                        val target = File(directory, fileName)
                        FileOutputStream(target).use { it.write(bytes) }
                        MediaScannerConnection.scanFile(
                            this,
                            arrayOf(target.absolutePath),
                            arrayOf("image/png"),
                            null,
                        )
                    }
                    result.success(true)
                } catch (error: Exception) {
                    result.error("SAVE_FAILED", error.message ?: "保存到相册失败", null)
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, STORAGE_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "pickDirectory") {
                    if (pendingDirectoryResult != null) {
                        result.error("BUSY", "文件夹选择正在进行", null)
                        return@setMethodCallHandler
                    }
                    pendingDirectoryResult = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                        addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                    }
                    startActivityForResult(intent, DIRECTORY_REQUEST)
                    return@setMethodCallHandler
                }
                if (call.method != "copyFileToDirectory") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val directoryUri = call.argument<String>("directoryUri")?.trim().orEmpty()
                val sourcePath = call.argument<String>("sourcePath")?.trim().orEmpty()
                val requestedName = call.argument<String>("fileName")?.trim().orEmpty()
                val mimeType = call.argument<String>("mimeType")?.trim().orEmpty()
                    .ifEmpty { "application/octet-stream" }
                if (!directoryUri.startsWith("content://") || sourcePath.isEmpty()) {
                    result.error("INVALID_STORAGE_REQUEST", "无效的目标文件夹或源文件", null)
                    return@setMethodCallHandler
                }
                val source = File(sourcePath)
                if (!source.isFile) {
                    result.error("SOURCE_NOT_FOUND", "下载文件不存在", null)
                    return@setMethodCallHandler
                }
                val safeName = requestedName
                    .replace(Regex("[\\\\/:*?\"<>|]"), "_")
                    .ifEmpty { "xy_music_${System.currentTimeMillis()}" }
                Thread {
                    try {
                        val treeUri = Uri.parse(directoryUri)
                        val parentDocumentUri = if (DocumentsContract.isTreeUri(treeUri)) {
                            DocumentsContract.buildDocumentUriUsingTree(
                                treeUri,
                                DocumentsContract.getTreeDocumentId(treeUri),
                            )
                        } else {
                            treeUri
                        }
                        val targetUri = DocumentsContract.createDocument(
                            contentResolver,
                            parentDocumentUri,
                            mimeType,
                            safeName,
                        ) ?: throw IllegalStateException("系统无法创建目标文件")
                        val output = contentResolver.openOutputStream(targetUri)
                            ?: throw IllegalStateException("系统无法打开目标文件")
                        source.inputStream().use { input ->
                            output.use { out -> input.copyTo(out) }
                        }
                        runOnUiThread { result.success(targetUri.toString()) }
                    } catch (error: Exception) {
                        runOnUiThread {
                            result.error(
                                "STORAGE_WRITE_FAILED",
                                error.message ?: "写入目标文件失败",
                                null,
                            )
                        }
                    }
                }.start()
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_INFO_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "getCrashDir") {
                    result.success(CrashHandler.crashDir(this).absolutePath)
                    return@setMethodCallHandler
                }
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

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        StoragePermissionBridge.onRequestPermissionsResult(requestCode, grantResults)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == DIRECTORY_REQUEST) {
            val result = pendingDirectoryResult
            pendingDirectoryResult = null
            if (resultCode != Activity.RESULT_OK || data?.data == null) {
                result?.success(null)
                return
            }
            val uri = data.data!!
            try {
                val takeFlags = data.flags and
                    (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                contentResolver.takePersistableUriPermission(uri, takeFlags)
            } catch (_: Exception) {
                // Some document providers do not support persisted grants; the
                // current activity grant is still valid for this session.
            }
            result?.success(uri.toString())
            return
        }
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
