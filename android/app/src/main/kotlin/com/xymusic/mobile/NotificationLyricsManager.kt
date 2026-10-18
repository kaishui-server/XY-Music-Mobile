package com.xymusic.mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.KeyEvent
import android.widget.RemoteViews
import androidx.core.app.NotificationCompat
import com.ryanheise.audioservice.MediaButtonReceiver

/**
 * 通知栏&锁屏实时歌词（任务A：蓝牙歌词补强）。
 *
 * 职责：
 * - 以「通知栏歌词通知」形式展示当前播放歌曲的实时歌词行，锁屏同样可见；
 * - 原生侧持有整首 LRC 行数组，用墙钟（elapsedRealtime）按播放进度推进
 *   当前行，仅在行变化时更新 RemoteViews（避免通知节流/抖动）；
 * - Flutter 侧通过 MethodChannel（com.xymusic.mobile/notification_lyrics）
 *   推送：歌曲元数据 + 整首 LRC + 进度锚点 + 播放态；切歌时 LRC 变化即
 *   重置并立即显示新歌歌词；
 * - 保留蓝牙歌词开关语义：通知栏歌词跟随 bluetoothLyricsEnabled 开关。
 *
 * 华为（HarmonyOS）防「通知栏越权闪退」措施：
 * 1. 不申请任何额外权限。仅复用清单已声明的 POST_NOTIFICATIONS；
 *    Android 13+ 未授予通知权限时自动降级为「仅内部更新，不发通知」，
 *    绝不触发系统权限异常。
 * 2. 只用 NotificationCompat 标准字段 + 静态 RemoteViews 布局
 *    （res/layout/lyrics_notification.xml），更新仅 setTextViewText，
 *    不动态加载 URL/图片/外部 View，不使用 setFullScreenIntent。
 * 3. 所有通知发布/更新路径 try/catch 兜底，任何 ROM 特有问题都只丢
 *    该次更新，不影响播放进程。
 */
object NotificationLyricsManager {
    const val CHANNEL = "com.xymusic.mobile/notification_lyrics"

    private const val CHANNEL_ID = "xy_lyrics_notification"
    private const val CHANNEL_NAME = "歌词通知"
    private const val NOTIFICATION_ID = 0x6C01 // "歌词" 语义 ID，避开媒体通知段

    private const val TICK_MS = 200L

    /** 单行 LRC 条目。 */
    private data class LyricLine(val timeMs: Long, val text: String)

    private var context: Context? = null
    private var manager: NotificationManager? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    // ---- 当前歌词状态 ----
    private var lines: List<LyricLine> = emptyList()
    private var currentIndex = -1
    private var title = ""
    private var artist = ""

    /** Flutter 侧歌词状态：loading=正在加载 / loaded=已加载 / none=确认无歌词。 */
    private var lyricsStatus = "loading"

    // ---- 进度锚点（原生按墙钟推进，Flutter 低频校准）----
    private var anchorPositionMs = 0L
    private var anchorRealtimeMs = 0L
    private var durationMs = 0L
    private var playing = false

    private var tickerRunning = false
    private val ticker = object : Runnable {
        override fun run() {
            if (!playing) {
                tickerRunning = false
                return
            }
            val pos = currentPositionMs()
            if (durationMs > 0 && pos > durationMs + 1500) {
                // 超出时长（播放结束/切歌前）停止推进，等待新锚点。
                tickerRunning = false
                return
            }
            if (applyPosition(pos, force = false)) {
                publish()
            }
            mainHandler.postDelayed(this, TICK_MS)
        }
    }

    /** 原生按墙钟外推的当前播放位置（毫秒）。 */
    private fun currentPositionMs(): Long {
        val elapsed = SystemClock.elapsedRealtime() - anchorRealtimeMs
        return anchorPositionMs + elapsed
    }

    /** 开启/恢复通知栏歌词（幂等）。 */
    @Synchronized
    fun enable(ctx: Context) {
        context = ctx.applicationContext
        manager = ctx.applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return
        ensureChannel()
    }

    /** 停止并移除通知栏歌词（幂等）。 */
    @Synchronized
    fun disable(ctx: Context) {
        stopTicker()
        val mgr = ctx.applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        runCatching { mgr?.cancel(NOTIFICATION_ID) }
        // 关闭蓝牙歌词：媒体通知（AudioService 媒体卡片）第二行恢复纯歌手。
        syncAudioServiceSecondLine(null)
        lines = emptyList()
        currentIndex = -1
        title = ""
        artist = ""
        playing = false
        context = null
        manager = null
    }

    /**
     * Flutter 进度流推送：切歌/歌词变化/播放态变化/进度校准都走这里。
     *
     * @param lyricRaw 整首 LRC 原文（切歌时变化即触发重新解析与重置）
     */
    @Synchronized
    fun update(
        ctx: Context,
        newTitle: String,
        newArtist: String,
        lyricRaw: String,
        positionMs: Long,
        isPlaying: Boolean,
        newDurationMs: Long,
        lyricsStatus: String,
    ) {
        val appCtx = ctx.applicationContext
        val mgr = appCtx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return
        context = appCtx
        manager = mgr
        ensureChannel()

        val titleChanged = newTitle != title || newArtist != artist
        if (titleChanged) {
            title = newTitle
            artist = newArtist
        }
        if (newDurationMs > 0) durationMs = newDurationMs

        // 采纳 Flutter 的歌词状态。切歌且新歌词尚未加载时保持 loading，
        // 避免在歌词异步加载完成前误显示「暂无歌词」。
        if (lyricsStatus == "loaded" ||
            lyricsStatus == "none" ||
            lyricsStatus == "loading"
        ) {
            if (titleChanged && lyricRaw.isBlank() && lyricsStatus == "loading") {
                // 新歌未带歌词：占位加载中。
                lines = emptyList()
                currentIndex = -1
            }
            this.lyricsStatus = lyricsStatus
        }

        // 切歌/首次/歌词变更：重新解析行数组并立即跳到新歌当前行。
        // 歌词已加载（loaded）时即使解析不到标准行也要做纯文本兜底，
        // 保证「有歌词的歌曲」不会显示「暂无歌词」。
        if (titleChanged || lyricRaw.isNotEmpty()) {
            val parsed = parseLyrics(lyricRaw)
            if (parsed != lines) {
                lines = parsed
                currentIndex = -1
            }
        }

        // 更新锚点：无论是否变化都校准，seek/暂停/恢复后墙钟外推都准确。
        anchorPositionMs = positionMs
        anchorRealtimeMs = SystemClock.elapsedRealtime()
        playing = isPlaying

        if (playing) {
            startTicker()
        } else {
            stopTicker()
        }

        if (titleChanged || lines.isEmpty()) {
            currentIndex = -1
            publish()
        } else if (applyPosition(positionMs, force = true)) {
            publish()
        }
    }

    /** 是否为 XML 声明 / DOCTYPE 元信息行（非歌词正文，禁止透传到通知栏）。 */
    private fun isXmlDeclaration(text: String): Boolean {
        val t = text.trim()
        return (t.startsWith("<?xml") && t.endsWith(">")) ||
            (t.startsWith("<!DOCTYPE") && t.endsWith(">"))
    }

    /** 解析 LRC：取时间标签与正文，按时间排序，丢弃纯元数据行。 */
    private fun parseLyrics(raw: String): List<LyricLine> {
        val out = mutableListOf<LyricLine>()
        if (raw.isBlank()) return out
        val tagPattern = Regex("""\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?]""")
        for (rawLine in raw.split(Regex("""\r?\n"""))) {
            val line = rawLine.trim()
            if (line.isEmpty() || isXmlDeclaration(line)) continue
            val tags = tagPattern.findAll(line).toList()
            if (tags.isEmpty()) continue
            val text = line.replace(tagPattern, "").replace(Regex("""[\u0000-\u001F]"""), "").trim()
            if (text.isEmpty()) continue
            for (tag in tags) {
                val minute = tag.groupValues[1].toLongOrNull() ?: 0L
                val second = tag.groupValues[2].toLongOrNull() ?: 0L
                val fracText = tag.groupValues[3]
                val frac = if (fracText.isEmpty()) 0L
                else {
                    val n = fracText.toLongOrNull() ?: 0L
                    when (fracText.length) {
                        1 -> n * 100
                        2 -> n * 10
                        else -> n
                    }
                }
                out.add(LyricLine(minute * 60000 + second * 1000 + frac, text))
            }
        }
        if (out.size > 1) out.sortBy { it.timeMs }
        if (out.isEmpty()) {
            // 兜底：标准 LRC 解析不到行（纯文本歌词/无时间标签/解析失败）时，
            // 取首个非空正文行显示，保证「有歌词的歌曲」不会显示「暂无歌词」。
            val metaPattern = Regex(
                """^\[(ar|ti|al|by|offset|length|re|ve|au|la|language):.*]$""",
                RegexOption.IGNORE_CASE,
            )
            for (rawLine in raw.split(Regex("""\r?\n"""))) {
                val text = rawLine
                    .replace(tagPattern, "")
                    .replace(Regex("""[\u0000-\u001F]"""), "")
                    .trim()
                if (text.isEmpty() || isXmlDeclaration(text) || metaPattern.matches(text)) continue
                out.add(LyricLine(0L, text))
                break
            }
        }
        return out
    }

    /**
     * 按位置推进当前行。返回是否发生了行变化（需要重新 notify）。
     *
     * @param force true 时即使行索引相同也视为已消费（用于锚点校准后的
     *              首帧发布）；实际是否 notify 由 [applyPosition] 内部判断。
     */
    private fun applyPosition(posMs: Long, force: Boolean): Boolean {
        if (lines.isEmpty()) return false
        // 二分找最后一条 time <= pos 的行。
        var lo = 0
        var hi = lines.size - 1
        var idx = -1
        while (lo <= hi) {
            val mid = (lo + hi) ushr 1
            if (lines[mid].timeMs <= posMs) {
                idx = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        if (idx < 0) idx = 0
        if (idx == currentIndex) return force
        currentIndex = idx
        return true
    }

    private fun startTicker() {
        if (tickerRunning) return
        tickerRunning = true
        mainHandler.removeCallbacks(ticker)
        mainHandler.post(ticker)
    }

    private fun stopTicker() {
        tickerRunning = false
        mainHandler.removeCallbacks(ticker)
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = manager?.getNotificationChannel(CHANNEL_ID)
            if (ch == null) {
                runCatching {
                    manager?.createNotificationChannel(
                        NotificationChannel(
                            CHANNEL_ID,
                            CHANNEL_NAME,
                            NotificationManager.IMPORTANCE_LOW,
                        ).apply {
                            description = "播放时显示实时滚动歌词"
                            setShowBadge(false)
                            enableVibration(false)
                            enableLights(false)
                        },
                    )
                }
            }
        }
    }

    /** 当前歌词行文本；无歌词时返回占位。 */
    private fun currentLyricText(): String {
        if (lines.isEmpty()) {
            // 无歌词时按歌词状态区分文案：正在加载显示占位，
            // 只有确认无歌词（none）才显示「暂无歌词」。
            return when (lyricsStatus) {
                "loading" -> "歌词加载中"
                else -> "暂无歌词"
            }
        }
        val idx = if (currentIndex < 0) 0 else currentIndex
        val text = lines[idx].text
        return if (text.isBlank()) "暂无歌词" else text
    }

    /** 反射调用 AudioService.setMediaSecondLine，避免 app 模块编译期解析
     *  audio_service 的 androidx.media 类型层级（MediaBrowserServiceCompat）。 */
    private fun syncAudioServiceSecondLine(value: String?) {
        runCatching {
            val m = Class.forName("com.ryanheise.audioservice.AudioService")
                .getMethod("setMediaSecondLine", String::class.java)
            m.invoke(null, value)
        }.onFailure {
            // 反射失败（如 R8 裁剪方法）原先被静默吞掉，歌词注入失效无从
            // 定位；透出 logcat 便于真机排查。
            android.util.Log.w("NotificationLyrics", "setMediaSecondLine 反射调用失败", it)
        }
    }

    /** 同步 AudioService 媒体通知第二行的叠加歌词行（歌手位）。 */
    private fun syncMediaSecondLine() {
        val lyric = currentLyricText()
        if (lyric.isBlank() || lyric == "暂无歌词" || lyric == "歌词加载中") {
            syncAudioServiceSecondLine(null)
        } else {
            syncAudioServiceSecondLine(lyric)
        }
    }

    /**
     * 同步媒体卡片第二行歌词（双卡片修复后的唯一出口）。
     *
     * 不再独立发布自定义歌词通知（NOTIFICATION_ID=0x6C01 发布路径已停用）：
     * 华为/HarmonyOS 通知栏同一时刻只保留 AudioService 构建的系统
     * MediaStyle 原生媒体卡片，逐行歌词通过 setMediaSecondLine 叠加到该
     * 卡片歌手位（蓝牙歌词开启时），避免同一时刻出现两张 XY Music 媒体
     * 卡片。蓝牙歌词关闭时由 [disable] 调用 syncAudioServiceSecondLine(null)
     * 恢复纯歌手名。全链路 try/catch（见 syncMediaSecondLine 内），
     * 任何 ROM 异常只丢该次同步，不影响播放进程。
     */
    private fun publish() {
        syncMediaSecondLine()
    }
}
