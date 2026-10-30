package com.xymusic.mobile

import android.app.Activity
import android.content.ComponentCallbacks2
import android.content.ContentValues
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Debug
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.MediaStore
import android.provider.DocumentsContract
import android.provider.Settings
import android.view.KeyEvent
import android.view.WindowManager
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.webkit.MimeTypeMap
import android.media.AudioManager
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
        private const val EXTERNAL_LINK_CHANNEL = "com.xymusic.mobile/external_link"
        private const val DESKTOP_LYRICS_CHANNEL = "com.xymusic.mobile/desktop_lyrics"
        private const val BLUETOOTH_LYRICS_CHANNEL = "com.xymusic.mobile/bluetooth_lyrics"
        private const val NOTIFICATION_LYRICS_CHANNEL =
            "com.xymusic.mobile/notification_lyrics"
        private const val SCREEN_AWAKE_CHANNEL = "com.xymusic.mobile/screen_awake"
        private const val DNS_LOOKUP_CHANNEL = "com.xymusic.mobile/dns_lookup"
        private const val GALLERY_CHANNEL = "com.xymusic.mobile/gallery"
        private const val STORAGE_CHANNEL = "com.xymusic.mobile/storage"
        private const val DEEPLINK_CHANNEL = "com.xymusic.mobile/deeplink"
        private const val MEDIA_BUTTON_CHANNEL = "com.xymusic.mobile/media_buttons"
        private const val VOLUME_KEY_CHANNEL = "com.xymusic.mobile/volume_keys"
        private const val MINI_PLAYER_CHANNEL = "com.xymusic.mobile/mini_player"
        private const val SYSTEM_UI_CHANNEL = "com.xymusic.mobile/system_ui"
        private const val MEMORY_PRESSURE_CHANNEL = "com.xymusic.mobile/memory_pressure"
        private const val CAPTURE_REQUEST = 4217
        private const val DIRECTORY_REQUEST = 4218
    }

    private var pendingStartResult: MethodChannel.Result? = null
    private var pendingDirectoryResult: MethodChannel.Result? = null
    private var deepLinkChannel: MethodChannel? = null
    private var pendingDeepLink: String? = null
    private var memoryPressureChannel: MethodChannel? = null
    // 内存治理 ⑪：Native Heap 周期监控（60s）。超阈值时向 Dart 发事件，
    // 由 Dart 侧重建播放器/清缓存降级；小米机型阈值单独下调（⑫）。
    private val memoryMonitorHandler = Handler(Looper.getMainLooper())
    private val memoryMonitorRunnable = object : Runnable {
        override fun run() {
            try {
                val info = Debug.MemoryInfo()
                Debug.getMemoryInfo(info)
                val thresholdMb = if (isXiaomiDevice()) 700 else 900
                if (info.nativePss > thresholdMb * 1024) {
                    memoryPressureChannel?.invokeMethod(
                        "nativePressure",
                        mapOf(
                            "nativePssKb" to info.nativePss,
                            "isXiaomi" to isXiaomiDevice(),
                        ),
                    )
                }
            } catch (_: Exception) {
            }
            memoryMonitorHandler.postDelayed(this, 60_000)
        }
    }

    private fun isXiaomiDevice(): Boolean {
        val m = Build.MANUFACTURER?.lowercase() ?: return false
        return m.contains("xiaomi") || m.contains("redmi") || m.contains("poco")
    }

    private var mediaButtonChannel: MethodChannel? = null

    /// 迷你播放器悬浮窗通道：Dart 侧据此启停浮窗、同步播放状态，并接收
    /// 浮窗内按钮/进度条的操作回调。
    private var miniPlayerChannel: MethodChannel? = null

    /// 桌面歌词通道：Dart 侧据此启停浮窗、同步状态，并接收浮窗操作栏
    /// 的回调（字号调节/锁定切换/设置键/关闭）。
    private var desktopLyricsChannelRef: MethodChannel? = null

    /// 通知栏双击（自动开桌面歌词）或浮窗 ⚙ 设置键（打开设置页）发生在
    /// Flutter 引擎就绪前（冷启动）时暂存动作名，等通道建好再转发。
    private var pendingDesktopLyricsAction: String? = null

    /// 「音量键调节应用内音量」开关由 Flutter 侧推送（setCaptureEnabled），
    /// 现仅用于悬浮窗音量条分流（开启调应用内音量，关闭调系统音量）；
    /// 前台物理音量键不再拦截——始终调节系统媒体音量。
    private var volumeKeyChannel: MethodChannel? = null

    /// 全局 Wi-Fi 高性能锁：阻止系统在播放/加载期间让 Wi-Fi 进入省电
    /// 模式拖慢网络。实测 HyperOS（小米）等 ROM 的省电策略会限制网络
    /// 吞吐，表现为歌曲加载极慢（CDN 连接 8 秒以上），开启系统录屏后
    /// 因系统持有性能锁而恢复正常。App 主动持锁等价于常驻该状态。
    @Suppress("DEPRECATION")
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        // Rust std::env::temp_dir() 在 Android 上默认解析为 /data/local/tmp
        //（应用 UID 无权写入），流缓存建文件恒失败（os error 2）→ DSP 接管
        // 恒回退原生输出，音效广场在线流永远无效。进程级 TMPDIR 指向应用
        // 缓存目录后，Rust 侧 temp_dir 与 Dart 侧 Directory.systemTemp 一并
        // 修复；getCacheDir() 保证目录存在，无需额外 mkdir。
        try {
            android.system.Os.setenv("TMPDIR", cacheDir.absolutePath, true)
        } catch (_: Exception) {
        }
        super.onCreate(savedInstanceState)
        // 尽早安装，捕获进程内所有线程的未捕获异常并写入崩溃文件。
        CrashHandler.install(this)
        // 久播卡死诊断：独立线程采集退出原因/主线程卡顿/内存趋势，
        // 落盘 crash-freeze.txt（随「崩溃记录」一起导出）。
        FreezeProbe.start(this)
        // 冷启动深链暂存：Flutter 引擎就绪后由 getInitialDeepLink 取走。
        pendingDeepLink = extractDeepLink(intent)
        // 通知栏双击（自动开桌面歌词）/浮窗 ⚙ 设置键的冷启动转发。
        handleDesktopLyricsIntent(intent)
        acquirePlaybackWifiLock()
        // 内存治理 ⑪：Native Heap 周期监控启动（首个周期 60s 后）。
        memoryMonitorHandler.postDelayed(memoryMonitorRunnable, 60_000)
    }

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        // 内存治理 ⑥：系统内存压力回调，通知 Dart 清理非关键缓存；
        // 后台未播放时 Dart 侧会彻底释放播放器（stop→reset→release）。
        if (level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_MODERATE) {
            memoryPressureChannel?.invokeMethod(
                "onTrimMemory",
                mapOf("level" to level, "isXiaomi" to isXiaomiDevice()),
            )
        }
    }

    override fun onDestroy() {
        try {
            wifiLock?.release()
        } catch (_: Exception) {
        }
        wifiLock = null
        memoryMonitorHandler.removeCallbacks(memoryMonitorRunnable)
        super.onDestroy()
    }

    private fun canDrawOverlaysCompat(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            Settings.canDrawOverlays(this)

    /// 播放期 Wi-Fi 锁使用 WIFI_MODE_FULL_HIGH_PERF：禁用 Wi-Fi 省电，
    /// 保持天线高性能收发。API 34 起该模式被标记废弃（系统认为默认
    /// 已足够），但在厂商省电激进的 ROM 上仍然有效。
    @Suppress("DEPRECATION")
    private fun acquirePlaybackWifiLock() {
        if (wifiLock != null) return
        try {
            val manager = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
            wifiLock = manager.createWifiLock(
                WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                "xymusic_playback",
            ).apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (_: Exception) {
            // 持锁失败不影响正常功能，仅回退到系统默认调度。
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // 热启动深链：直接转发给 Flutter 侧处理。
        extractDeepLink(intent)?.let { raw ->
            deepLinkChannel?.invokeMethod("onDeepLink", raw)
        }
        // 浮窗 ⚙ 设置键的热启动转发（通知点击/胶囊单击进软件由 Receiver
        // 直接拉起 Activity，无需额外动作）。
        handleDesktopLyricsIntent(intent)
    }

    /// 分发桌面歌词相关的启动意图：
    /// - extra `open_desktop_lyrics_settings`：浮窗 ⚙ 设置键 → 请求 Dart
    ///   打开桌面歌词设置页。
    /// 通道未就绪（冷启动早于 Flutter 引擎）时暂存动作名。
    /// 历史上的 `auto_enable_desktop_lyrics`（通知双击自动开歌词）已移除：
    /// MagicOS 胶囊单击常被拆成两次广播误入双击链，无权限时会弹授权页。
    private fun handleDesktopLyricsIntent(intent: Intent?) {
        if (intent?.getBooleanExtra("open_desktop_lyrics_settings", false) != true) {
            return
        }
        val method = "onOpenSettings"
        val channel = desktopLyricsChannelRef
        val dartReady = channel != null &&
            flutterEngine?.dartExecutor?.isExecutingDart == true
        if (dartReady) {
            // 热启动：Dart 侧 handler 必然已装好（PlayerNotifier 构造时
            // ensureReady），invoke 直达（pending 不暂存——否则残留会在
            // 下次冷启动被 ensureReady 重复拉取，误开一次设置页）。
            try {
                channel!!.invokeMethod(method, null)
            } catch (_: Exception) {
                // 引擎已销毁时忽略。
            }
        } else {
            // 冷启动早期：configureFlutterEngine 早于 Dart 侧
            // setMethodCallHandler 安装，invoke 到达时通道无接收端会静默
            // 丢失——暂存给 Dart ensureReady 启动时主动拉取（拉取即清空）。
            pendingDesktopLyricsAction = method
        }
    }

    /// 音频效果能力探测结果缓存（null 表示尚未探测）。
    @Volatile
    private var audioEffectsProbe: Map<String, Boolean>? = null

    /// 探测音频 HAL 是否提供系统均衡器/响度增益效果。
    ///
    /// 部分机型（实测 OnePlus Android 16）的音频 HAL 不含均衡器实现，
    /// `android.media.audiofx.AudioEffect` 构造时抛 RuntimeException
    /// （"Cannot initialize effect engine for type: 0bed4300-... Error: -3"）。
    /// just_audio 一旦被注入 AndroidEqualizer，就会在 audio session 建立
    /// （每次 load / 切歌）时构造 Equalizer；该异常发生在主线程且无人
    /// 捕获，会直接把整个进程判为崩溃退出。这里试建一次得出能力结论，
    /// 宿主据此决定是否向播放管线注入对应效果。
    ///
    /// 探测分两档（缺一不可）：
    /// 1. 全局会话（0）：判断本机音频 HAL 是否具备该效果；
    /// 2. 真实播放会话：华为 MatePad SE 等机型全局会话 0 能建效果，但
    ///    绑定到真实播放会话时构造抛 RuntimeException
    ///    （"AudioEffect: set/get parameter error"）——just_audio 正是拿
    ///    播放会话构造效果，异常在主线程无人捕获即崩溃。只看会话 0 会漏判，
    ///    这里用临时 AudioTrack 取到与播放同类的真实会话再试一次。
    private fun probeAudioEffects(): Map<String, Boolean> {
        audioEffectsProbe?.let { return it }
        val globalEqualizer = canCreateAudioEffect {
            android.media.audiofx.Equalizer(0, 0).release()
        }
        val globalLoudness = canCreateAudioEffect {
            android.media.audiofx.LoudnessEnhancer(0).release()
        }
        val realSession = probeAudioEffectsOnRealSession()
        val result = mapOf(
            "equalizer" to (globalEqualizer && realSession.first),
            "loudnessEnhancer" to (globalLoudness && realSession.second),
        )
        audioEffectsProbe = result
        return result
    }

    /// 用临时 AudioTrack 拿到真实播放会话 id，并在该会话上试建效果。
    ///
    /// 返回 (equalizer, loudnessEnhancer)。拿不到真实会话（AudioTrack 构造
    /// 失败或返回会话 0）时一律按「不支持」处理：宁可该机型降级没有系统
    /// 音效，也不能让 just_audio 在真实会话上构造效果时崩溃。
    private fun probeAudioEffectsOnRealSession(): Pair<Boolean, Boolean> {
        var track: android.media.AudioTrack? = null
        try {
            val sampleRate = 44100
            val minBuffer = android.media.AudioTrack.getMinBufferSize(
                sampleRate,
                android.media.AudioFormat.CHANNEL_OUT_STEREO,
                android.media.AudioFormat.ENCODING_PCM_16BIT,
            )
            val bufferSize = if (minBuffer > 0) minBuffer else 8192
            track = android.media.AudioTrack.Builder()
                .setAudioAttributes(
                    android.media.AudioAttributes.Builder()
                        .setUsage(android.media.AudioAttributes.USAGE_MEDIA)
                        .setContentType(android.media.AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build(),
                )
                .setAudioFormat(
                    android.media.AudioFormat.Builder()
                        .setEncoding(android.media.AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(sampleRate)
                        .setChannelMask(android.media.AudioFormat.CHANNEL_OUT_STEREO)
                        .build(),
                )
                .setBufferSizeInBytes(bufferSize)
                .setTransferMode(android.media.AudioTrack.MODE_STREAM)
                .build()
            val sessionId = track.audioSessionId
            if (sessionId == 0) return false to false
            val equalizer = canCreateAudioEffect {
                android.media.audiofx.Equalizer(0, sessionId).release()
            }
            val loudness = canCreateAudioEffect {
                android.media.audiofx.LoudnessEnhancer(sessionId).release()
            }
            return equalizer to loudness
        } catch (_: Throwable) {
            return false to false
        } finally {
            try {
                track?.release()
            } catch (_: Throwable) {
            }
        }
    }

    private inline fun canCreateAudioEffect(create: () -> Unit): Boolean =
        try {
            create()
            true
        } catch (_: Throwable) {
            false
        }

    /// 是否已被系统豁免电池优化（后台保活状态）。
    private fun isIgnoringBatteryOptimizations(): Boolean = try {
        val pm = getSystemService(android.content.Context.POWER_SERVICE) as PowerManager
        pm.isIgnoringBatteryOptimizations(packageName)
    } catch (_: Throwable) {
        false
    }

    /// 拉起系统「忽略电池优化」授权弹窗。部分 ROM 没有该弹窗或不允许直接
    /// 跳转，此时回退到应用详情页。返回是否成功拉起。
    private fun requestIgnoreBatteryOptimizations(): Boolean = try {
        startActivity(
            Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                data = Uri.parse("package:$packageName")
            },
        )
        true
    } catch (_: Throwable) {
        try {
            startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.parse("package:$packageName")
                },
            )
            true
        } catch (_: Throwable) {
            false
        }
    }

    /// 提取 xymusic:// 深链（分享落地页拉起播放）。
    private fun extractDeepLink(intent: Intent?): String? {
        val data = intent?.data ?: return null
        val scheme = data.scheme ?: return null
        if (!scheme.equals("xymusic", ignoreCase = true)) return null
        val raw = data.toString()
        return raw.ifEmpty { null }
    }

    /// 把 SAF 写入用的 MIME 规范成具体类型。
    ///
    /// Dart 侧统一传 `audio/*` / `video/*` 这类通配 MIME，而
    /// `DocumentsContract.createDocument` 需要具体类型：通配 MIME 会被部分
    /// ROM（如鸿蒙）原样写进文档元数据，系统文件管理器据此解析不出可用的
    /// 播放器，打开下载歌曲时提示「当前文件格式不支持」。这里按扩展名解析，
    /// 解析不出来再按大类兜底给一个具体类型。
    private fun resolveDocumentMimeType(fileName: String, requested: String): String {
        val req = requested.trim()
        if (req.isNotEmpty() && !req.contains('*')) return req
        val ext = fileName.substringAfterLast('.', "").lowercase()
        val byExtension = when (ext) {
            "mp3" -> "audio/mpeg"
            "flac" -> "audio/flac"
            "m4a", "mp4a" -> "audio/mp4"
            "aac" -> "audio/aac"
            "ogg", "oga" -> "audio/ogg"
            "opus" -> "audio/opus"
            "wav" -> "audio/wav"
            "ape" -> "audio/x-ape"
            "wma" -> "audio/x-ms-wma"
            "dsf" -> "audio/x-dsf"
            "dff" -> "audio/x-dff"
            "mp4" -> "video/mp4"
            "mkv" -> "video/x-matroska"
            "webm" -> "video/webm"
            "mov" -> "video/quicktime"
            "lrc", "txt" -> "text/plain"
            else -> null
        }
        if (byExtension != null) return byExtension
        val fromSystem = if (ext.isNotEmpty()) {
            MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
        } else {
            null
        }
        if (!fromSystem.isNullOrEmpty()) return fromSystem
        return when {
            req.startsWith("video/") -> "video/mp4"
            req.startsWith("image/") -> "image/jpeg"
            req.startsWith("text/") -> "text/plain"
            else -> "audio/mpeg"
        }
    }

    /// 把本地文件写入 SAF 文档 URI，兼容鸿蒙的大文件限制。
    ///
    /// 鸿蒙（HarmonyOS）文件管理器提供的 SAF 通道对约 30MB 以上的大文件
    /// （母带/高码率 FLAC 常见）会中途截断：本地写入计数、provider 上报的
    /// 文件大小都看似完整，但落盘内容不完整，表现为下载后的母带在应用内
    /// 与系统播放器里都无法识别（提示格式不支持）。因此优先解析出真实
    /// 文件路径直接写盘（见 [writeFileByRealPath]），解析不到或没有按路径
    /// 写权限时再退回 SAF 流式写入：用 `openFileDescriptor` 拿 PFD 后直接
    /// 用 `FileOutputStream` 按 1MB 分块写入并 fsync，写入后校验字节数，
    /// 不一致直接抛错，避免静默产出坏文件。
    private fun writeFileToDocumentUri(uri: Uri, source: File) {
        // 优先按真实文件路径直写：鸿蒙文件管理器经 SAF 暴露的输出流对约
        // 30MB 以上的大文件（母带/高码率 FLAC 常见）会在中途放弃写入，
        // 且本地写入计数与 provider 上报的大小都「看似完整」，最终落盘
        // 文件在任意播放器里都识别不了。MusicFree、LX-X 等直接按路径写盘
        // 的应用没有该限制。createDocument 已建好目标文件，能解析出
        // primary 卷真实路径时直接写盘；解析不到（SD 卡/云盘等 provider）
        // 或没有按路径写权限（未授予「所有文件访问」）时退回 SAF 流式写入。
        val realPath = resolveRealPathForDocument(uri)
        if (realPath != null) {
            try {
                writeFileByRealPath(File(realPath), source)
                return
            } catch (_: Exception) {
                // 继续走 SAF 通道兜底。
            }
        }
        val total = source.length()
        var written = 0L

        val pfd = try {
            contentResolver.openFileDescriptor(uri, "rw")
        } catch (_: Exception) {
            null
        }

        if (pfd != null) {
            try {
                FileOutputStream(pfd.fileDescriptor).use { out ->
                    source.inputStream().use { input ->
                        val buffer = ByteArray(1 shl 20)
                        while (true) {
                            val read = input.read(buffer)
                            if (read <= 0) break
                            out.write(buffer, 0, read)
                            written += read
                        }
                        out.flush()
                        // 大文件关闭前落盘，避免部分 ROM 只在文件描述符关闭后
                        // 才异步提交，导致系统侧看到的仍是「未落定」的文件。
                        try {
                            out.fd.sync()
                        } catch (_: Exception) {
                        }
                    }
                }
            } finally {
                try {
                    pfd.close()
                } catch (_: Exception) {
                }
            }
        } else {
            // 回退：部分 provider 不支持 openFileDescriptor。用 "wa"
            // （write + append/create）而非 "w"，前者不会先截断，对大文件
            // 更稳；仍拿不到再退回默认 "w"。
            val output = contentResolver.openOutputStream(uri, "wa")
                ?: contentResolver.openOutputStream(uri)
                ?: throw IllegalStateException("系统无法打开目标文件")
            output.use { out ->
                source.inputStream().use { input ->
                    val buffer = ByteArray(1 shl 20)
                    while (true) {
                        val read = input.read(buffer)
                        if (read <= 0) break
                        out.write(buffer, 0, read)
                        written += read
                    }
                    out.flush()
                }
            }
        }

        // 落盘校验：写入字节数或实际文件大小不足原始大小都视为失败，直接
        // 报错让 Dart 侧提示重试，而不是留下一个打不开的坏文件。
        val onDisk = try {
            contentResolver.openFileDescriptor(uri, "r")?.use { it.statSize }
        } catch (_: Exception) {
            null
        }
        if (written < total || (onDisk != null && onDisk >= 0 && onDisk < total)) {
            throw IllegalStateException(
                "目标文件写入不完整（预期 $total 字节，实际 $written 字节" +
                    (if (onDisk != null && onDisk >= 0) "，落盘 $onDisk 字节" else "") + "）",
            )
        }
    }

    /// 按真实文件路径直写目标文件，绕开鸿蒙 SAF 通道的大文件截断限制。
    ///
    /// 先写同目录临时文件，校验字节数后再原子重命名到目标：既能写入任意
    /// 大小（与 MusicFree、LX-X 的按路径写盘一致），失败时也不会留下半截
    /// 坏文件——临时文件会被清理，目标仍是 createDocument 建好的空文件。
    private fun writeFileByRealPath(target: File, source: File) {
        val parent = target.parentFile
            ?: throw IllegalStateException("目标文件没有父目录")
        val total = source.length()
        val temp = File(parent, ".${target.name}.xymusic.tmp")
        try {
            FileOutputStream(temp, false).use { out ->
                source.inputStream().use { input ->
                    val buffer = ByteArray(1 shl 20)
                    while (true) {
                        val read = input.read(buffer)
                        if (read <= 0) break
                        out.write(buffer, 0, read)
                    }
                    out.flush()
                    try {
                        out.fd.sync()
                    } catch (_: Exception) {
                    }
                }
            }
            if (temp.length() < total) {
                throw IllegalStateException(
                    "按路径写入不完整（预期 $total 字节，实际 ${temp.length()} 字节）",
                )
            }
            if (!temp.renameTo(target)) {
                throw IllegalStateException("无法替换目标文件")
            }
        } catch (error: Exception) {
            try {
                temp.delete()
            } catch (_: Exception) {
            }
            throw error
        }
    }

    /// 把 SAF 文档（`primary:Download/XY Music/xxx.flac` 形式）映射回真实
    /// 文件路径；非 ext4 类 provider 或解析失败时返回 null。
    private fun resolveRealPathForDocument(documentUri: Uri): String? {
        return try {
            val documentId = DocumentsContract.getDocumentId(documentUri) ?: return null
            val separator = documentId.indexOf(':')
            if (separator <= 0) return null
            val volume = documentId.substring(0, separator)
            val relative = documentId.substring(separator + 1)
            if (relative.isEmpty()) return null
            val root = if (volume.equals("primary", ignoreCase = true)) {
                Environment.getExternalStorageDirectory().absolutePath
            } else {
                "/storage/$volume"
            }
            val path = "$root/$relative"
            if (File(path).isFile) path else null
        } catch (_: Exception) {
            null
        }
    }

    /// 写入完成后主动登记系统媒体库。
    ///
    /// 母带/高码率 FLAC 等大文件（约 30MB 以上）经 SAF 通道写入后，部分
    /// ROM（鸿蒙）不会自动把它登记进媒体库：文件内容完整、任意应用按路径
    /// 都能读，但系统文件管理器解析不出类型，点击时提示「当前文件格式不
    /// 支持」。这里在写入成功后补一次媒体扫描（MIME 传 null 让系统按内容
    /// 嗅探），把文件与真实类型/大小登记进媒体库。
    private fun notifyMediaScanner(documentUri: Uri) {
        val path = resolveRealPathForDocument(documentUri) ?: return
        try {
            MediaScannerConnection.scanFile(this, arrayOf(path), null, null)
        } catch (_: Exception) {
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        StoragePermissionBridge.register(this, flutterEngine)
        BluetoothLyricsLink.register(flutterEngine.dartExecutor.binaryMessenger, this)
        // 可视化频谱桥：输出混音 FFT 采集（音乐可视化页数据源）。
        VisualizerBridge.register(flutterEngine.dartExecutor.binaryMessenger, this)
        // 通知栏&锁屏实时歌词：Flutter 推送元数据+LRC+进度锚点+播放态，
        // 原生侧按墙钟推进当前行并更新 RemoteViews（华为防越权：不申请
        // 额外权限、仅标准字段与静态布局、全部路径 try/catch 兜底）。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            NOTIFICATION_LYRICS_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") == true
                    try {
                        if (enabled) {
                            NotificationLyricsManager.enable(this)
                        } else {
                            NotificationLyricsManager.disable(this)
                        }
                        result.success(true)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }
                "update" -> {
                    NotificationLyricsManager.update(
                        this,
                        call.argument<String>("title") ?: "",
                        call.argument<String>("artist") ?: "",
                        call.argument<String>("lyrics") ?: "",
                        (call.argument<Number>("positionMs")?.toLong() ?: 0L),
                        call.argument<Boolean>("isPlaying") == true,
                        (call.argument<Number>("durationMs")?.toLong() ?: 0L),
                        call.argument<String>("lyricsStatus") ?: "loading",
                    )
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        mediaButtonChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            MEDIA_BUTTON_CHANNEL,
        )
        volumeKeyChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            VOLUME_KEY_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method == "setCaptureEnabled") {
                    val enabled = call.argument<Boolean>("enabled") == true
                    // 悬浮窗音量条跟随同一开关：开启只调应用内音量，关闭调系统音量。
                    MiniPlayerOverlayService.appVolumeMode = enabled
                    result.success(true)
                } else {
                    result.notImplemented()
                }
            }
        }
        // 内存治理通道：Dart 侧注册后主动拉取机型信息（getInitialInfo）；
        // 原生 onTrimMemory / Native Heap 监控超限时向 Dart 发事件。
        memoryPressureChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            MEMORY_PRESSURE_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method == "getInitialInfo") {
                    result.success(mapOf("isXiaomi" to isXiaomiDevice()))
                } else {
                    result.notImplemented()
                }
            }
        }
        val miniChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            MINI_PLAYER_CHANNEL,
        )
        miniPlayerChannel = miniChannel
        // 浮窗按钮/进度条操作回传 Dart：在播放层执行切歌/暂停/seek。
        MiniPlayerOverlayService.actionReporter = { action, value ->
            try {
                miniChannel.invokeMethod(
                    "onAction",
                    mapOf("action" to action, "value" to value),
                )
            } catch (_: Exception) {
                // 引擎已销毁时忽略。
            }
        }
        // 浮窗关闭按钮被点击后回传 Dart，同步关闭设置里的迷你播放器开关。
        MiniPlayerOverlayService.closeReporter = {
            try {
                miniChannel.invokeMethod("onCloseRequested", null)
            } catch (_: Exception) {
                // 引擎已销毁时忽略。
            }
        }
        miniChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "hasOverlayPermission" -> {
                    result.success(
                        Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
                            Settings.canDrawOverlays(this)
                    )
                }
                "requestOverlayPermission" -> {
                    startActivity(
                        Intent(
                            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                            Uri.parse("package:$packageName"),
                        ),
                    )
                    result.success(null)
                }
                "setEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") == true
                    // 仅「设置页手动开启」允许拉起授权页；自动同步链路（进
                    // app 恢复状态等）必须静默，否则开关残留为开 + 权限未授
                    // 时，用户每次打开 app 都会被拉到悬浮窗授权页。
                    val requestPermission =
                        call.argument<Boolean>("requestPermission") != false
                    if (!enabled) {
                        stopService(Intent(this, MiniPlayerOverlayService::class.java))
                        result.success(true)
                        return@setMethodCallHandler
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
                        !Settings.canDrawOverlays(this)
                    ) {
                        if (requestPermission) {
                            startActivity(
                                Intent(
                                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                    Uri.parse("package:$packageName"),
                                ),
                            )
                        }
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    try {
                        startService(
                            Intent(this, MiniPlayerOverlayService::class.java).apply {
                                action = MiniPlayerOverlayService.ACTION_SHOW
                            },
                        )
                        result.success(true)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }
                "update" -> {
                    val params = MiniPlayerUpdateParams(
                        title = call.argument<String>("title") ?: "",
                        artist = call.argument<String>("artist") ?: "",
                        isPlaying = call.argument<Boolean>("isPlaying") == true,
                        isLoading = call.argument<Boolean>("isLoading") == true,
                        positionMs = call.argument<Number>("positionMs")?.toLong() ?: 0L,
                        durationMs = call.argument<Number>("durationMs")?.toLong() ?: 0L,
                        playMode = call.argument<Number>("playMode")?.toInt() ?: 0,
                        coverPath = call.argument<String>("coverPath") ?: "",
                        queueJson = call.argument<String>("queueJson") ?: "",
                        queueIndex = call.argument<Number>("queueIndex")?.toInt() ?: -1,
                        // 应用内音量与分流模式：此前漏读导致悬浮窗音量条
                        // 恒按系统音量处理（拖动直接写 STREAM_MUSIC），
                        // 且播放页菜单滑块拖动后音量条不跟随。
                        appVolume =
                            (call.argument<Number>("appVolume")?.toDouble() ?: 1.0)
                                .toFloat(),
                        appVolumeMode = call.argument<Boolean>("appVolumeMode") == true,
                    )
                    // 服务已在运行时直连分发，省去每次进度刷新的 startService
                    // binder 往返；未运行（被系统回收）时才拉起服务恢复浮窗。
                    val running = MiniPlayerOverlayService.instance
                    if (running != null) {
                        try {
                            running.applyUpdate(params)
                            result.success(true)
                        } catch (_: Exception) {
                            result.success(false)
                        }
                        return@setMethodCallHandler
                    }
                    try {
                        startService(
                            Intent(this, MiniPlayerOverlayService::class.java).apply {
                                action = MiniPlayerOverlayService.ACTION_UPDATE
                                putExtra("title", params.title)
                                putExtra("artist", params.artist)
                                putExtra("isPlaying", params.isPlaying)
                                putExtra("isLoading", params.isLoading)
                                putExtra("positionMs", params.positionMs)
                                putExtra("durationMs", params.durationMs)
                                putExtra("playMode", params.playMode)
                                putExtra("coverPath", params.coverPath)
                                putExtra("queueJson", params.queueJson)
                                putExtra("queueIndex", params.queueIndex)
                                putExtra("appVolume", params.appVolume)
                                putExtra("appVolumeMode", params.appVolumeMode)
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
        // 冷启动期间到达的通知双击/⚙ 设置键请求：**不**在这里立即补发。
        // configureFlutterEngine 执行时 Dart isolate 可能尚未运行、原生
        // → Dart 的 invokeMethod 会静默丢失（且 pending 已被清空，用户
        // 再点一次才生效）；改为 Dart 侧 handler 安装后主动调用
        // `getPendingDesktopLyricsAction` 拉取（见下方 method call
        // handler 与 desktop_lyrics.dart 的 ensureReady）。
        deepLinkChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DEEPLINK_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method != "getInitialDeepLink") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val initial = pendingDeepLink
                pendingDeepLink = null
                result.success(initial)
            }
        }
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
        // 系统栏沉浸控制：API 30+ 用 WindowInsetsController 硬隐藏状态栏
        // （Android 15 强制 edge-to-edge 后 SystemChrome 的 immersive 在
        // 部分机型失效，此为可视化页兜底）；API < 30 由 Dart 侧
        // SystemChrome 兜底，这里返回 false。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SYSTEM_UI_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "setStatusBarHidden") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val hidden = call.argument<Boolean>("hidden") == true
                runOnUiThread {
                    val controller: WindowInsetsController? = window.insetsController
                    if (controller == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
                        result.success(false)
                        return@runOnUiThread
                    }
                    if (hidden) {
                        controller.systemBarsBehavior =
                            WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                        controller.hide(WindowInsets.Type.statusBars())
                    } else {
                        controller.show(WindowInsets.Type.statusBars())
                    }
                    result.success(true)
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DNS_LOOKUP_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "lookup") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val host = call.argument<String>("host")?.trim().orEmpty()
                if (host.isEmpty()) {
                    result.error("invalid_host", "host is empty", null)
                    return@setMethodCallHandler
                }
                // Java 层 DNS 解析走系统 netd 缓存，与 ExoPlayer 共享：
                // 播放前预解析可填充缓存，setUrl 的连接阶段直接命中。
                // 解析结果同时回传（地址与耗时），用于诊断慢连接根因。
                Thread {
                    val started = System.currentTimeMillis()
                    try {
                        val addresses = java.net.InetAddress.getAllByName(host)
                        val elapsed = System.currentTimeMillis() - started
                        val list = addresses.map { it.hostAddress ?: "" }
                            .filter { it.isNotEmpty() }
                        result.success(
                            mapOf(
                                "elapsedMs" to elapsed,
                                "addresses" to list,
                            )
                        )
                    } catch (error: Exception) {
                        val elapsed = System.currentTimeMillis() - started
                        result.success(
                            mapOf(
                                "elapsedMs" to elapsed,
                                "error" to (error.message ?: error.toString()),
                            )
                        )
                    }
                }.start()
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
                if (call.method == "hasDirectoryGrant") {
                    val directoryUri = call.argument<String>("directoryUri")?.trim().orEmpty()
                    if (!directoryUri.startsWith("content://")) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    try {
                        val treeUri = Uri.parse(directoryUri)
                        if (!DocumentsContract.isTreeUri(treeUri)) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        // 授权可能因重装应用、恢复备份或系统回收而丢失；
                        // 写入前先确认本进程仍持有该目录的持久化写授权。
                        val treeId = DocumentsContract.getTreeDocumentId(treeUri)
                        val granted = contentResolver.persistedUriPermissions.any { perm ->
                            if (!perm.isWritePermission) return@any false
                            if (perm.uri == treeUri) return@any true
                            try {
                                DocumentsContract.isTreeUri(perm.uri) &&
                                    perm.uri.authority == treeUri.authority &&
                                    DocumentsContract.getTreeDocumentId(perm.uri) == treeId
                            } catch (_: Exception) {
                                false
                            }
                        }
                        result.success(granted)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                    return@setMethodCallHandler
                }
                if (call.method == "deleteFile") {
                    val target = call.argument<String>("uri")?.trim().orEmpty()
                    if (!target.startsWith("content://")) {
                        result.error("INVALID_STORAGE_REQUEST", "无效的目标文件", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        try {
                            val deleted = DocumentsContract.deleteDocument(
                                contentResolver,
                                Uri.parse(target),
                            )
                            runOnUiThread { result.success(deleted) }
                        } catch (error: Exception) {
                            runOnUiThread {
                                result.error(
                                    "STORAGE_DELETE_FAILED",
                                    error.message ?: "删除目标文件失败",
                                    null,
                                )
                            }
                        }
                    }.start()
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
                            resolveDocumentMimeType(safeName, mimeType),
                            safeName,
                        ) ?: throw IllegalStateException("系统无法创建目标文件")
                        writeFileToDocumentUri(targetUri, source)
                        notifyMediaScanner(targetUri)
                        runOnUiThread { result.success(targetUri.toString()) }
                    } catch (error: Exception) {
                        val message = error.message ?: ""
                        val permissionDenied = error is SecurityException ||
                            message.contains("Permission Denial") ||
                            message.contains("MANAGE_DOCUMENTS") ||
                            message.contains("grantUriPermission")
                        runOnUiThread {
                            result.error(
                                if (permissionDenied) "STORAGE_PERMISSION_DENIED" else "STORAGE_WRITE_FAILED",
                                if (permissionDenied)
                                    "下载目录的访问授权已失效（可能因重装应用或恢复备份丢失），请重新选择下载目录"
                                else
                                    message.ifEmpty { "写入目标文件失败" },
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
                if (call.method == "probeAudioEffects") {
                    result.success(probeAudioEffects())
                    return@setMethodCallHandler
                }
                // 后台保活引导：查询/请求忽略电池优化。国内 ROM（华为等）的
                // 省电策略会强杀前台服务，导致后台播放中断甚至进程被杀。
                if (call.method == "isIgnoringBatteryOptimizations") {
                    result.success(isIgnoringBatteryOptimizations())
                    return@setMethodCallHandler
                }
                if (call.method == "requestIgnoreBatteryOptimizations") {
                    result.success(requestIgnoreBatteryOptimizations())
                    return@setMethodCallHandler
                }
                // 久播卡死探针：上报系统音频输出层信号。Dart 侧据
                // isMusicActive 区分「进度停滞但系统无音乐输出」的
                // AudioTrack/AAudio 停摆，与媒体层停滞相互印证。
                if (call.method == "audioProbe") {
                    // 刷新 Dart 探针时间戳：据此推算 Dart 主 isolate 是否停摆。
                    FreezeProbe.noteDartProbe()
                    val payload = try {
                        val am = getSystemService(AUDIO_SERVICE) as AudioManager
                        mapOf(
                            "isMusicActive" to am.isMusicActive,
                            "musicVolume" to am.getStreamVolume(AudioManager.STREAM_MUSIC),
                            "musicVolumeMax" to am.getStreamMaxVolume(AudioManager.STREAM_MUSIC),
                            "mode" to am.mode,
                        )
                    } catch (_: Exception) {
                        mapOf("isMusicActive" to null)
                    }
                    result.success(payload)
                    return@setMethodCallHandler
                }
                if (call.method == "getStorageRoots") {
                    // 枚举可用的存储卷根（含外置 SD 卡）：getExternalFilesDirs
                    // 返回每个卷上的应用专属目录，从其路径推出卷根
                    // /storage/XXXX-XXXX。部分 ROM（华为等）限制第三方 app
                    // 直接枚举 /storage 目录，走系统 API 最可靠；再按挂载
                    // 状态过滤，未挂载/已拔出的卷不返回。
                    val roots = mutableListOf<String>()
                    for (dir in getExternalFilesDirs(null)) {
                        if (dir == null) continue
                        val path = dir.absolutePath
                        if (!path.startsWith("/storage/")) continue
                        // 未挂载/已拔出的卷直接跳过。
                        if (android.os.Environment.getExternalStorageState(dir) !=
                            android.os.Environment.MEDIA_MOUNTED
                        ) {
                            continue
                        }
                        // 主存储（模拟卷 /storage/emulated/0）由 Dart 侧固定
                        // 提供，这里只返回物理外置卷（SD 卡等）。不过滤的话
                        // 主存储条目会被误推出 /storage/emulated（少一层 /0）。
                        if (android.os.Environment.isExternalStorageEmulated(dir)) {
                            continue
                        }
                        val volume = path.removePrefix("/storage/")
                            .substringBefore('/')
                        if (volume.isEmpty()) continue
                        val root = "/storage/$volume"
                        if (root !in roots) roots.add(root)
                    }
                    result.success(roots)
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
        // 外部链接：交给系统浏览器 / 已注册应用打开（关于页的仓库、创作者、
        // 参考项目等链接）。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, EXTERNAL_LINK_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "openUrl") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val url = call.argument<String>("url")?.trim().orEmpty()
                if (url.isEmpty()) {
                    result.error("INVALID_URL", "链接为空", null)
                    return@setMethodCallHandler
                }
                try {
                    val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    startActivity(intent)
                    result.success(true)
                } catch (error: Exception) {
                    result.error("OPEN_FAILED", error.message ?: "无法打开链接", null)
                }
            }
        val desktopLyricsChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DESKTOP_LYRICS_CHANNEL)
        desktopLyricsChannelRef = desktopLyricsChannel
        // 手动拖动浮窗后把纵向位置（百分制）回传 Dart，让设置页滑块与
        // 实际位置同步，避免下一次进度更新用旧滑块值把浮窗拉回（位置复位）。
        DesktopLyricsService.positionReporter = { percent ->
            try {
                desktopLyricsChannel.invokeMethod("onPositionChanged", percent)
            } catch (_: Exception) {
                // 引擎已销毁时忽略。
            }
        }
        // 浮窗关闭按钮被点击后回传 Dart，同步关闭设置里的桌面歌词开关。
        DesktopLyricsService.closeReporter = {
            try {
                desktopLyricsChannel.invokeMethod("onCloseRequested", null)
            } catch (_: Exception) {
                // 引擎已销毁时忽略。
            }
        }
        // 操作栏 A-/A+ 调节字号后回传 Dart：设置页滑块跟随并持久化。
        DesktopLyricsService.fontSizeReporter = { size ->
            try {
                desktopLyricsChannel.invokeMethod("onFontScaleChanged", size)
            } catch (_: Exception) {
                // 引擎已销毁时忽略。
            }
        }
        // 操作栏锁定键切换后回传 Dart：设置页「锁定桌面歌词」开关跟随。
        DesktopLyricsService.lockedReporter = { locked ->
            try {
                desktopLyricsChannel.invokeMethod("onLockedChanged", locked)
            } catch (_: Exception) {
                // 引擎已销毁时忽略。
            }
        }
        // 操作栏播放三键：转发 Dart 直接控制播放（prev/playPause/next）。
        DesktopLyricsService.mediaKeyReporter = { action ->
            try {
                desktopLyricsChannel.invokeMethod("onMediaKey", action)
            } catch (_: Exception) {
                // 引擎已销毁时忽略。
            }
        }
        desktopLyricsChannel
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Dart 侧 handler 就绪后主动拉取冷启动期间暂存的动作。
                    // 冷启动时原生 configureFlutterEngine 远早于 Dart isolate
                    // 的 setMethodCallHandler 安装，立即 invoke 的消息会直接
                    // 丢失且 pending 已被清空——改为 Dart 拉取才可靠。
                    "getPendingDesktopLyricsAction" -> {
                        val action = pendingDesktopLyricsAction
                        pendingDesktopLyricsAction = null
                        result.success(action)
                    }
                    "setEnabled" -> {
                        val enabled = call.argument<Boolean>("enabled") == true
                        if (!enabled) {
                            stopService(Intent(this, DesktopLyricsService::class.java))
                            result.success(true)
                            return@setMethodCallHandler
                        }
                        // 仅手动开启（requestPermission != false）才允许拉起
                        // 授权页；自动链路静默失败，规范见 setEnabled 文档。
                        val requestPermission =
                            call.argument<Boolean>("requestPermission") != false
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
                            !Settings.canDrawOverlays(this)
                        ) {
                            if (requestPermission) {
                                startActivity(
                                    Intent(
                                        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                        Uri.parse("package:$packageName"),
                                    ),
                                )
                            }
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
                        val params = DesktopLyricsUpdateParams(
                            lyric = call.argument<String>("lyric") ?: "",
                            translation = call.argument<String>("translation") ?: "",
                            wordsJson = call.argument<String>("wordsJson") ?: "[]",
                            position = call.argument<Number>("position")?.toDouble() ?: 0.0,
                            isPlaying = call.argument<Boolean>("isPlaying") == true,
                            hideOnPause = call.argument<Boolean>("hideOnPause") == true,
                            effectMode = call.argument<Number>("wordEffectMode")?.toInt() ?: 2,
                            locked = call.argument<Boolean>("locked") == true,
                            noBackground = call.argument<Boolean>("noBackground") != false,
                            lyricColor = call.argument<Number>("lyricColor")?.toInt()
                                ?: 0xFFFFFFFF.toInt(),
                            translationColor = call.argument<Number>("translationColor")?.toInt()
                                ?: 0xFFE1E1E6.toInt(),
                            lyricFontSize = call.argument<Number>("lyricFontSize")?.toFloat() ?: 24f,
                            translationFontSize = call.argument<Number>("translationFontSize")
                                ?.toFloat() ?: 13f,
                            backgroundColor = call.argument<Number>("backgroundColor")?.toInt()
                                ?: 0xFF18181C.toInt(),
                            backgroundOpacity = call.argument<Number>("backgroundOpacity")
                                ?.toFloat() ?: .85f,
                            verticalPercent = call.argument<Number>("verticalPercent")
                                ?.toFloat() ?: 90f,
                            lyricFontPath = call.argument<String>("lyricFontPath") ?: "",
                        )
                        // 服务已在运行时直连分发，省去每次进度刷新的
                        // startService binder 往返；未运行（被系统回收）时
                        // 走 startService 拉起并携带完整状态恢复浮窗。
                        val running = DesktopLyricsService.instance
                        if (running != null) {
                            try {
                                running.applyUpdate(params)
                                result.success(true)
                            } catch (_: Exception) {
                                result.success(false)
                            }
                            return@setMethodCallHandler
                        }
                        try {
                            startService(
                                Intent(this, DesktopLyricsService::class.java).apply {
                                    action = DesktopLyricsService.ACTION_UPDATE
                                    putExtra("lyric", params.lyric)
                                    putExtra("translation", params.translation)
                                    putExtra("wordsJson", params.wordsJson)
                                    putExtra("position", params.position)
                                    putExtra("isPlaying", params.isPlaying)
                                    putExtra("hideOnPause", params.hideOnPause)
                                    putExtra("wordEffectMode", params.effectMode)
                                    putExtra("locked", params.locked)
                                    putExtra("noBackground", params.noBackground)
                                    putExtra("lyricColor", params.lyricColor)
                                    putExtra("translationColor", params.translationColor)
                                    putExtra("lyricFontSize", params.lyricFontSize)
                                    putExtra("translationFontSize", params.translationFontSize)
                                    putExtra("backgroundColor", params.backgroundColor)
                                    putExtra("backgroundOpacity", params.backgroundOpacity)
                                    putExtra("verticalPercent", params.verticalPercent)
                                    putExtra("lyricFontPath", params.lyricFontPath)
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

    /// 车机/方向盘按键兜底：部分车机 ROM 不把媒体按键交给 MediaSession，
    /// 而是直接注入前台 Activity。这里拦截媒体键并转发给 Flutter 侧，
    /// 保证在绕过媒体会话的设备上也能切歌/暂停。
    /// 标准 Android 上媒体键优先派发给活跃 MediaSession（audio_service 已
    /// 处理 click/skipToNext/skipToPrevious），不会到达这里，因此不会重复触发。
    /// 仅在 ACTION_DOWN 且非重复按（repeatCount==0）时转发一次，
    /// 避免 AVRCP 长按连发导致连续切歌；对应的 ACTION_UP 直接吞掉。
    override fun dispatchKeyEvent(event: KeyEvent?): Boolean {
        if (event != null) {
            // 物理音量键不再拦截：无论应用是否前台，音量键始终调节系统
            // 媒体音量（系统音量再影响本应用播放响度，属单向影响、不改写
            // 应用内音量值）。车机媒体键兜底转发保留。
            val action = mediaButtonAction(event.keyCode)
            if (action != null) {
                if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
                    mediaButtonChannel?.invokeMethod("onMediaButton", action)
                }
                return true
            }
        }
        return super.dispatchKeyEvent(event)
    }

    private fun mediaButtonAction(keyCode: Int): String? = when (keyCode) {
        KeyEvent.KEYCODE_MEDIA_NEXT -> "next"
        KeyEvent.KEYCODE_MEDIA_PREVIOUS -> "previous"
        KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
        KeyEvent.KEYCODE_HEADSETHOOK,
        -> "playPause"
        KeyEvent.KEYCODE_MEDIA_PLAY -> "play"
        KeyEvent.KEYCODE_MEDIA_PAUSE -> "pause"
        KeyEvent.KEYCODE_MEDIA_STOP -> "stop"
        KeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> "fastForward"
        KeyEvent.KEYCODE_MEDIA_REWIND -> "rewind"
        else -> null
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
        BluetoothLyricsLink.onPermissionResult(requestCode, grantResults)
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
