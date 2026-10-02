package com.xymusic.mobile

import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.ColorDrawable
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import android.provider.Settings
import android.text.Layout
import android.text.SpannableString
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.view.Choreographer
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.MotionEvent
import android.widget.LinearLayout
import android.widget.TextView
import org.json.JSONArray
import kotlin.math.abs

/** 桌面歌词单次更新参数。MainActivity 通过 [DesktopLyricsService.instance]
 * 直连调用 applyUpdate，避免每次进度刷新都走一次 startService 的 binder
 * 往返（原生侧进度同步高频到达，直连可显著降低主线程与 AMS 开销）。 */
class DesktopLyricsUpdateParams(
    val lyric: String,
    val translation: String,
    val wordsJson: String,
    val position: Double,
    val isPlaying: Boolean,
    val effectMode: Int,
    val locked: Boolean,
    val noBackground: Boolean,
    val lyricColor: Int,
    val translationColor: Int,
    val lyricFontSize: Float,
    val translationFontSize: Float,
    val backgroundColor: Int,
    val backgroundOpacity: Float,
    /** 上下位移（dp）：叠加在拖动基准位置之上的垂直偏移，正值上移。 */
    val verticalOffset: Float,
    /** 状态栏避让：开启时浮窗顶部不越过状态栏下沿。 */
    val avoidStatusBar: Boolean,
    /** 自定义字体文件绝对路径（空 = 系统默认），供 Typeface.createFromFile。 */
    val lyricFontPath: String,
)

/** 系统级桌面歌词浮窗。只展示当前歌曲和当前时间点歌词，不抢占焦点。 */
class DesktopLyricsService : Service() {
    companion object {
        const val ACTION_SHOW = "com.xymusic.mobile.desktop_lyrics.SHOW"
        const val ACTION_UPDATE = "com.xymusic.mobile.desktop_lyrics.UPDATE"
        const val ACTION_STOP = "com.xymusic.mobile.desktop_lyrics.STOP"

        /** 与 Dart 侧 LyricWordEffectMode 枚举序号保持一致。 */
        const val EFFECT_WORD_BY_WORD = 0
        const val EFFECT_PROGRESSIVE = 1
        const val EFFECT_NONE = 2

        /** 运行中的服务实例，供 MainActivity 直连分发 update。 */
        @Volatile
        var instance: DesktopLyricsService? = null

        private fun wordProgress(span: WordSpan, position: Double): Double = when {
            position <= span.timeStart -> 0.0
            position >= span.timeEnd || span.timeEnd <= span.timeStart -> 1.0
            else -> ((position - span.timeStart) / (span.timeEnd - span.timeStart))
                .coerceIn(0.0, 1.0)
        }
    }

    /** 单个词在歌词文本中的字符区间与时间轴（词级，不做字符拆分：
     * 渐进填充的连续扫光由 [KaraokeTextView] 逐帧裁剪绘制）。 */
    private class WordSpan(
        val start: Int,
        val end: Int,
        val timeStart: Double,
        val timeEnd: Double,
    )

    private var windowManager: WindowManager? = null
    private var panel: View? = null
    private var lyricView: TextView? = null
    private var translationView: TextView? = null
    private var overlayParams: WindowManager.LayoutParams? = null
    private var downX = 0f
    private var downY = 0f
    private var startX = 0
    private var startY = 0

    // ---- 位置与字体状态 ----
    /** 用户拖动确定的基准 y（不含滑块偏移），单位 px，自屏幕底部起算。 */
    private var baseY = 76
    /** 设置页「上下位移」滑块值（dp），叠加在基准位置之上。 */
    private var verticalOffsetDp = 0f
    /** 状态栏避让：开启时浮窗顶部不越过状态栏下沿。 */
    private var avoidStatusBar = true
    /** 已应用的自定义字体路径（空 = 系统默认），避免重复创建 Typeface。 */
    private var appliedFontPath: String? = null

    // ---- 逐字渲染状态 ----
    // Dart 侧只按内容变化/低频(500ms)位置校正推送，帧循环用 Choreographer
    // 每帧把播放位置按经过的墙钟时间前推：渐进填充连续扫光、逐词高亮
    // 平滑过渡，均与播放详情页同级流畅度。
    private var wordSpans: List<WordSpan> = emptyList()
    private var wordColorSpans: Array<ForegroundColorSpan?> = emptyArray()
    private var wordText: SpannableString? = null
    private var lyricBaseColor = Color.WHITE
    private var basePosition = 0.0
    private var baseUptimeMs = 0L
    private var lyricsPlaying = false
    private var wordEffectMode = EFFECT_NONE
    private var frameCallbackPosted = false

    // ---- 增量更新缓存：内容/样式未变化时跳过重建，只校正进度基准 ----
    private var lastContentKey: String? = null
    private var lastBackgroundKey: String? = null
    private var lastLyricColor = Color.WHITE
    private var lastTranslationColor = Color.argb(190, 225, 225, 230)

    private val frameCallback = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            frameCallbackPosted = false
            if (wordEffectMode == EFFECT_PROGRESSIVE) {
                // 所有词都唱完的行视觉已静止，跳过无谓的重绘。
                if (karaokeNeedsFrame(currentRenderPosition())) {
                    (lyricView as? KaraokeTextView)?.invalidate()
                }
            } else {
                renderWordProgress()
            }
            maybePostNextFrame()
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_SHOW, ACTION_UPDATE, null -> {
                if (!canDrawOverlays()) {
                    stopSelf()
                    return START_NOT_STICKY
                }
                ensurePanel()
                intent?.let { applyUpdate(paramsFromIntent(it)) }
            }
        }
        return START_STICKY
    }

    private fun canDrawOverlays(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(this)

    private fun paramsFromIntent(intent: Intent) = DesktopLyricsUpdateParams(
        lyric = intent.getStringExtra("lyric").orEmpty(),
        translation = intent.getStringExtra("translation").orEmpty(),
        wordsJson = intent.getStringExtra("wordsJson").orEmpty(),
        position = intent.getDoubleExtra("position", 0.0),
        isPlaying = intent.getBooleanExtra("isPlaying", false),
        effectMode = intent.getIntExtra("wordEffectMode", EFFECT_NONE),
        locked = intent.getBooleanExtra("locked", false),
        noBackground = intent.getBooleanExtra("noBackground", true),
        lyricColor = intent.getIntExtra("lyricColor", 0xFFFFFFFF.toInt()),
        translationColor = intent.getIntExtra("translationColor", 0xFFE1E1E6.toInt()),
        lyricFontSize = intent.getFloatExtra("lyricFontSize", 24f),
        translationFontSize = intent.getFloatExtra("translationFontSize", 13f),
        backgroundColor = intent.getIntExtra("backgroundColor", 0xFF18181C.toInt()),
        backgroundOpacity = intent.getFloatExtra("backgroundOpacity", .85f),
        verticalOffset = intent.getFloatExtra("verticalOffset", 0f),
        avoidStatusBar = intent.getBooleanExtra("avoidStatusBar", true),
        lyricFontPath = intent.getStringExtra("lyricFontPath").orEmpty(),
    )

    private fun ensurePanel() {
        if (panel != null) return
        val lyric = KaraokeTextView(this).apply {
            setTextColor(Color.WHITE)
            textSize = 24f
            typeface = android.graphics.Typeface.create(
                android.graphics.Typeface.DEFAULT,
                android.graphics.Typeface.BOLD,
            )
            maxLines = 2
            ellipsize = android.text.TextUtils.TruncateAt.END
            gravity = Gravity.CENTER
            textAlignment = View.TEXT_ALIGNMENT_CENTER
            setLineSpacing(0f, 1.3f)
            positionProvider = { currentRenderPosition() }
        }
        val translation = TextView(this).apply {
            setTextColor(Color.argb(190, 225, 225, 230))
            textSize = 12f
            typeface = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                android.graphics.Typeface.create(
                    android.graphics.Typeface.DEFAULT,
                    800,
                    false,
                )
            } else {
                android.graphics.Typeface.create(
                    android.graphics.Typeface.DEFAULT,
                    android.graphics.Typeface.BOLD,
                )
            }
            maxLines = 2
            ellipsize = android.text.TextUtils.TruncateAt.END
            gravity = Gravity.CENTER
            textAlignment = View.TEXT_ALIGNMENT_CENTER
            setLineSpacing(0f, 1.25f)
        }
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(28, 15, 28, 15)
            addView(lyric, LinearLayout.LayoutParams(-1, -2))
            addView(translation, LinearLayout.LayoutParams(-1, -2))
            background = GradientDrawable().apply {
                cornerRadius = 32f
                setColor(Color.argb(218, 24, 24, 28))
                setStroke(1, Color.argb(75, 255, 255, 255))
            }
        }
        lyricView = lyric
        translationView = translation
        panel = content
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
            val prefs = getSharedPreferences("desktop_lyrics", MODE_PRIVATE)
            x = prefs.getInt("x", 0)
            baseY = prefs.getInt("y", 76)
            y = baseY
        }
        overlayParams = params
        content.setOnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = event.rawX
                    downY = event.rawY
                    startX = params.x
                    startY = baseY
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    params.x = startX + (event.rawX - downX).toInt()
                    // 拖动只改变不含滑块偏移的基准位置，实际 y 再叠加
                    // 偏移并做状态栏避让钳制。
                    baseY = startY - (event.rawY - downY).toInt()
                    params.y = clampY(baseY + verticalOffsetPx())
                    try {
                        windowManager?.updateViewLayout(content, params)
                    } catch (_: Exception) {
                        // 系统回收浮窗时忽略最后一次拖动。
                    }
                    true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    // 持久化基准位置（不含滑块偏移），避免下次启动重复叠加。
                    getSharedPreferences("desktop_lyrics", MODE_PRIVATE)
                        .edit()
                        .putInt("x", params.x)
                        .putInt("y", baseY)
                        .apply()
                    true
                }
                else -> true
            }
        }
        // 浮窗首次测量/内容高度变化时重算 y：状态栏避让的上边界依赖
        // 浮窗实际高度，布局完成前拿不到，需在布局变化后补一次钳制。
        content.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
            applyWindowPosition()
        }
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        try {
            windowManager?.addView(content, params)
        } catch (_: Exception) {
            panel = null
            lyricView = null
            translationView = null
            overlayParams = null
            stopSelf()
        }
    }

    /// 统一更新入口（直连与 Intent 两条路径共用）。
    ///
    /// 性能要点（修复卡顿）：
    /// 1. 内容键（歌词/翻译/逐字数据/模式/颜色）未变化时跳过 JSON 解析、
    ///    Spannable 重建与 setText 重排版，只做进度基准校正；
    /// 2. 进度基准平滑校正——Dart 推来的 position 含传输延迟，比当前
    ///    Choreographer 外推值略微滞后；小偏差（<0.35s）保留旧基准继续
    ///    外推，避免每次同步把填充边界向后拽形成周期性锯齿。暂停/恢复/
    ///    大偏差（seek）才重置基准。
    fun applyUpdate(p: DesktopLyricsUpdateParams) {
        if (!canDrawOverlays()) {
            stopSelf()
            return
        }
        ensurePanel()
        val lyric = p.lyric.ifBlank { "暂无歌词" }

        // 位置/字体类参数：滑块位移、状态栏避让、自定义字体。这些参数
        // 变化频率极低（仅用户调节时推送），每次更新时幂等应用即可。
        verticalOffsetDp = p.verticalOffset
        avoidStatusBar = p.avoidStatusBar
        applyFont(p.lyricFontPath)
        applyWindowPosition()

        overlayParams?.let { params ->
            val desiredFlags = WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                if (p.locked) WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE else 0
            if (params.flags != desiredFlags) {
                params.flags = desiredFlags
                try {
                    panel?.let { windowManager?.updateViewLayout(it, params) }
                } catch (_: Exception) {
                    // 浮窗已被系统回收时忽略状态更新。
                }
            }
        }

        val wasPlaying = lyricsPlaying
        val deviation = p.position - currentRenderPosition()
        val snapBase = !wasPlaying || !p.isPlaying || abs(deviation) > 0.35
        if (snapBase) {
            basePosition = p.position
            baseUptimeMs = SystemClock.elapsedRealtime()
        }
        lyricsPlaying = p.isPlaying
        wordEffectMode = p.effectMode

        val contentKey = "$lyric\u0000${p.translation}\u0000${p.wordsJson}" +
            "\u0000${p.effectMode}\u0000${p.lyricColor}"
        if (contentKey != lastContentKey) {
            lastContentKey = contentKey
            lyricBaseColor = p.lyricColor
            wordSpans = parseWordSpans(lyric, p.wordsJson, p.effectMode)
            wordColorSpans = arrayOfNulls(wordSpans.size)
            (lyricView as? KaraokeTextView)?.setKaraokeData(
                wordSpans,
                p.effectMode,
                p.lyricColor,
            )
            // 渐进填充由 KaraokeTextView 自绘（无 span）；逐词切换仍用
            // ForegroundColorSpan 按整词插值。
            val styled = if (p.effectMode == EFFECT_WORD_BY_WORD && wordSpans.isNotEmpty()) {
                buildWordStyledText(lyric)
            } else {
                wordText = null
                null
            }
            if (styled != null) {
                lyricView?.setText(styled, TextView.BufferType.SPANNABLE)
            } else {
                lyricView?.setText(lyric, TextView.BufferType.SPANNABLE)
            }
            if (lastLyricColor != p.lyricColor) {
                lastLyricColor = p.lyricColor
                lyricView?.setTextColor(p.lyricColor)
            }
        } else if (wasPlaying != p.isPlaying || snapBase) {
            // 进度基准变化（暂停/恢复/seek）但内容未变：按新位置立即重画。
            (lyricView as? KaraokeTextView)?.invalidate()
        }
        if (!lyricsPlaying && wordEffectMode == EFFECT_WORD_BY_WORD) {
            renderWordProgress()
        }

        translationView?.let { view ->
            if (view.text.toString() != p.translation) {
                view.text = p.translation
            }
            // 无翻译且无罗马音的歌曲不显示副行：空文本的 TextView 仍会
            // 占一行高度，副行残留为空白行，因此按内容显隐整个视图。
            val translationVisible = p.translation.isNotBlank()
            val desiredVisibility =
                if (translationVisible) View.VISIBLE else View.GONE
            if (view.visibility != desiredVisibility) {
                view.visibility = desiredVisibility
            }
            if (lastTranslationColor != p.translationColor) {
                lastTranslationColor = p.translationColor
                view.setTextColor(p.translationColor)
            }
            val translationFontSize = p.translationFontSize.coerceIn(10f, 28f)
            if (abs(
                    view.textSize -
                        translationFontSize * resources.displayMetrics.scaledDensity,
                ) > .5f
            ) {
                view.textSize = translationFontSize
            }
        }
        val lyricFontSize = p.lyricFontSize.coerceIn(16f, 40f)
        lyricView?.let { view ->
            if (abs(
                    view.textSize -
                        lyricFontSize * resources.displayMetrics.scaledDensity,
                ) > .5f
            ) {
                view.textSize = lyricFontSize
            }
        }

        val backgroundKey = "${p.noBackground}|${p.backgroundColor}|${p.backgroundOpacity}"
        if (backgroundKey != lastBackgroundKey) {
            lastBackgroundKey = backgroundKey
            panel?.background = if (p.noBackground) {
                ColorDrawable(Color.TRANSPARENT)
            } else {
                GradientDrawable().apply {
                    cornerRadius = 32f
                    setColor(
                        Color.argb(
                            (p.backgroundOpacity * 255).toInt(),
                            Color.red(p.backgroundColor),
                            Color.green(p.backgroundColor),
                            Color.blue(p.backgroundColor),
                        ),
                    )
                    setStroke(1, Color.argb(75, 255, 255, 255))
                }
            }
        }
        maybePostNextFrame()
    }

    /// 解析逐字时间轴为词级 span。渐进填充不再按字符拆分——连续扫光
    /// 由 KaraokeTextView 对每个词按词进度水平裁剪绘制，与播放详情页
    /// 的硬边扫光完全一致；逐词切换保持整词跳变高亮。
    private fun parseWordSpans(
        lyric: String,
        wordsJson: String,
        effectMode: Int,
    ): List<WordSpan> {
        if (effectMode == EFFECT_NONE || wordsJson.isBlank() || lyric == "暂无歌词") {
            return emptyList()
        }
        return try {
            val words = JSONArray(wordsJson)
            if (words.length() == 0) return emptyList()
            val spans = ArrayList<WordSpan>(words.length())
            var cursor = 0
            for (index in 0 until words.length()) {
                val word = words.optJSONObject(index) ?: continue
                val text = word.optString("text", "")
                if (text.isEmpty()) continue
                val start = lyric.indexOf(text, cursor)
                if (start < 0) continue
                val end = (start + text.length).coerceAtMost(lyric.length)
                cursor = end
                val timeStart = word.optDouble("start", 0.0)
                val timeEnd = word.optDouble("end", timeStart)
                spans.add(WordSpan(start, end, timeStart, timeEnd))
            }
            spans
        } catch (_: Exception) {
            emptyList()
        }
    }

    /// 按 basePosition 一次性构建整行带颜色 span 的文本（供 setText）。
    /// 之后的进度推进只更新 span 颜色，不重建文本。
    private fun buildWordStyledText(lyric: String): SpannableString {
        val styled = SpannableString(lyric)
        val position = currentRenderPosition()
        for (index in wordSpans.indices) {
            val span = wordSpans[index]
            val color = interpolateColor(lyricBaseColor, wordProgress(span, position))
            val colorSpan = ForegroundColorSpan(color)
            wordColorSpans[index] = colorSpan
            styled.setSpan(
                colorSpan,
                span.start,
                span.end,
                Spanned.SPAN_EXCLUSIVE_EXCLUSIVE,
            )
        }
        wordText = styled
        return styled
    }

    /// 帧循环主体（逐词模式）：按前推后的播放位置更新每个词的颜色 span。
    /// 颜色未变化的词跳过 span 替换，未在演唱的行整帧零开销。
    private fun renderWordProgress() {
        val styled = wordText ?: return
        if (wordEffectMode != EFFECT_WORD_BY_WORD || wordSpans.isEmpty()) return
        val position = currentRenderPosition()
        for (index in wordSpans.indices) {
            val span = wordSpans[index]
            val progress = wordProgress(span, position)
            val newColor = interpolateColor(lyricBaseColor, progress)
            val existing = wordColorSpans.getOrNull(index) ?: continue
            if (existing.foregroundColor == newColor) continue
            styled.removeSpan(existing)
            val updated = ForegroundColorSpan(newColor)
            wordColorSpans[index] = updated
            styled.setSpan(
                updated,
                span.start,
                span.end,
                Spanned.SPAN_EXCLUSIVE_EXCLUSIVE,
            )
        }
    }

    /// 推算当前播放位置：basePosition + 自上次 Dart 进度同步以来经过的
    /// 墙钟时间（暂停时不前进）。
    private fun currentRenderPosition(): Double {
        if (!lyricsPlaying) return basePosition
        val elapsedSec = (SystemClock.elapsedRealtime() - baseUptimeMs) / 1000.0
        return basePosition + elapsedSec
    }

    /// 渐进模式下是否还需要逐帧重绘：只要还有未唱完/未开始的词就继续。
    private fun karaokeNeedsFrame(position: Double): Boolean {
        for (span in wordSpans) {
            if (position < span.timeEnd) return true
        }
        return false
    }

    /// 播放中且处于逐字模式时保持每帧回调；暂停或无逐字数据时停止，
    /// 避免悬浮窗在后台白白占用 CPU。
    private fun maybePostNextFrame() {
        val animatable =
            lyricsPlaying && wordEffectMode != EFFECT_NONE && wordSpans.isNotEmpty()
        if (animatable && !frameCallbackPosted) {
            frameCallbackPosted = true
            Choreographer.getInstance().postFrameCallback(frameCallback)
        } else if (!animatable) {
            Choreographer.getInstance().removeFrameCallback(frameCallback)
            frameCallbackPosted = false
        }
    }

    /// 逐词插值，与播放详情页同口径：暗色 = 基色 55% 透明度，
    /// 亮色 = 基色全量，进度在两者间线性过渡（Color.lerp 语义）。
    private fun interpolateColor(color: Int, progress: Double): Int {
        val alpha = (Color.alpha(color) * (0.55 + 0.45 * progress))
            .toInt()
            .coerceIn(0, 255)
        return Color.argb(
            alpha,
            Color.red(color),
            Color.green(color),
            Color.blue(color),
        )
    }

    // ---- 位置与字体应用 ----

    /** 滑块偏移换算为纵向像素（正值上移，浮窗 y 减小）。 */
    private fun verticalOffsetPx(): Int =
        (verticalOffsetDp * resources.displayMetrics.density).toInt()

    /** 状态栏高度（px）；取不到时回退 0。 */
    private fun statusBarHeight(): Int {
        val id = resources.getIdentifier("status_bar_height", "dimen", "android")
        if (id > 0) {
            val h = resources.getDimensionPixelSize(id)
            if (h > 0) return h
        }
        return 0
    }

    /** 导航栏高度（px）；取不到时回退 0。 */
    private fun navigationBarHeight(): Int {
        val id = resources.getIdentifier("navigation_bar_height", "dimen", "android")
        if (id > 0) {
            val h = resources.getDimensionPixelSize(id)
            if (h > 0) return h
        }
        return 0
    }

    /// 浮窗 y 钳制：下边界不小于 0（不越出屏幕底），开启状态栏避让时
    /// 上边界不超过「屏幕高 - 状态栏 - 导航栏 - 浮窗高」。
    private fun clampY(value: Int): Int {
        val screenHeight = resources.displayMetrics.heightPixels
        var maxY = screenHeight
        if (avoidStatusBar) {
            val panelHeight = panel?.height?.takeIf { it > 0 } ?: 0
            maxY = screenHeight - statusBarHeight() - navigationBarHeight() - panelHeight
        }
        return value.coerceIn(0, maxY.coerceAtLeast(0))
    }

    /** 按当前基准 + 滑块偏移重算 y 并下发。 */
    private fun applyWindowPosition() {
        val params = overlayParams ?: return
        val target = clampY(baseY + verticalOffsetPx())
        if (params.y != target) {
            params.y = target
            try {
                panel?.let { windowManager?.updateViewLayout(it, params) }
            } catch (_: Exception) {
                // 浮窗已被系统回收时忽略位置更新。
            }
        }
    }

    /// 应用自定义字体；路径为空或创建失败时回退系统默认字体。
    private fun applyFont(path: String) {
        if (path == appliedFontPath) return
        appliedFontPath = path
        val fallback = android.graphics.Typeface.create(
            android.graphics.Typeface.DEFAULT,
            android.graphics.Typeface.BOLD,
        )
        val custom = if (path.isEmpty()) {
            fallback
        } else {
            try {
                android.graphics.Typeface.createFromFile(path)
            } catch (_: Exception) {
                fallback
            }
        }
        lyricView?.typeface = custom
        translationView?.typeface = if (path.isEmpty()) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                android.graphics.Typeface.create(
                    android.graphics.Typeface.DEFAULT,
                    800,
                    false,
                )
            } else {
                fallback
            }
        } else {
            custom
        }
    }

    override fun onDestroy() {
        instance = null
        Choreographer.getInstance().removeFrameCallback(frameCallback)
        frameCallbackPosted = false
        panel?.let { view ->
            try {
                windowManager?.removeView(view)
            } catch (_: Exception) {
                // 浮窗已被系统回收。
            }
        }
        panel = null
        lyricView = null
        translationView = null
        overlayParams = null
        wordText = null
        wordSpans = emptyList()
        wordColorSpans = emptyArray()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /// 渐进填充歌词视图：完全继承播放详情页的渲染方式——
    /// 暗色整词（基色 55% 透明度）在下，亮色字形（基色全量）按词进度
    /// 水平裁剪从左到右扫过（硬边扫光，_SweepWordPainter 同款），
    /// 而不是按字符逐个点亮。
    private inner class KaraokeTextView(context: Context) : TextView(context) {
        var karaokeMode: Int = EFFECT_NONE
        var karaokeWords: List<WordSpan> = emptyList()
        var brightColor: Int = Color.WHITE
        var positionProvider: (() -> Double)? = null

        fun setKaraokeData(words: List<WordSpan>, mode: Int, baseColor: Int) {
            karaokeWords = words
            karaokeMode = mode
            brightColor = baseColor
            invalidate()
        }

        override fun onDraw(canvas: Canvas) {
            if (karaokeMode != EFFECT_PROGRESSIVE ||
                karaokeWords.isEmpty() ||
                text.isEmpty()
            ) {
                super.onDraw(canvas)
                return
            }
            val textLayout = layout
            val position = positionProvider?.invoke()
            if (textLayout == null || position == null) {
                super.onDraw(canvas)
                return
            }
            val textPaint = paint
            val dx = (paddingLeft + scrollX).toFloat()
            val dy = verticalTextOffset(textLayout).toFloat()
            // 暗色整行打底（基色 55% 透明度，与详情页未扫光词一致）。
            textPaint.color = dimColorOf(brightColor)
            canvas.save()
            canvas.translate(dx, dy)
            textLayout.draw(canvas)
            canvas.restore()
            // 亮色字形按每个词的进度水平裁剪扫过。
            textPaint.color = brightColor
            for (word in karaokeWords) {
                val progress = wordProgress(word, position)
                if (progress <= 0.0) continue
                drawSweptWord(canvas, textLayout, word, progress, dx, dy)
            }
        }

        /// 单词扫光：词跨行时按各行的字符段分别裁剪，段进度按该词总字符
        /// 数的占比线性映射（单行时与详情页按宽度线性扫光完全一致）。
        /// 段末边界落在换行处时经 [segmentEndX] 换算为该行行尾，规避
        /// getPrimaryHorizontal 在换行边界返回下一行行首坐标的问题。
        private fun drawSweptWord(
            canvas: Canvas,
            textLayout: Layout,
            word: WordSpan,
            progress: Double,
            dx: Float,
            dy: Float,
        ) {
            val textLen = text.length
            val end = word.end.coerceAtMost(textLen)
            if (end <= word.start) return
            val firstLine = textLayout.getLineForOffset(word.start)
            // 用词尾字符所在行定 lastLine：end 恰为换行边界时
            // getLineForOffset(end) 会选中下一行，凭空多出空段。
            val lastLine = textLayout.getLineForOffset(end - 1)
            val totalChars = (end - word.start).coerceAtLeast(1)
            for (line in firstLine..lastLine) {
                val segStart = if (line == firstLine) word.start else textLayout.getLineStart(line)
                val segEnd = if (line == lastLine) end
                else textLayout.getLineEnd(line).coerceAtMost(end)
                if (segEnd <= segStart) continue
                val cumStart = (segStart - word.start).toDouble() / totalChars
                val cumEnd = (segEnd - word.start).toDouble() / totalChars
                val segProgress = ((progress - cumStart) /
                    (cumEnd - cumStart).coerceAtLeast(1e-6)).coerceIn(0.0, 1.0)
                if (segProgress <= 0.0) continue
                var x0 = textLayout.getPrimaryHorizontal(segStart)
                var x1 = segmentEndX(textLayout, segEnd)
                if (x1 < x0) {
                    val tmp = x0
                    x0 = x1
                    x1 = tmp
                }
                val clipRight = x0 + (x1 - x0) * segProgress.toFloat()
                if (segProgress < 1.0 && clipRight - x0 < .5f) continue
                canvas.save()
                canvas.translate(dx, dy)
                canvas.clipRect(
                    x0,
                    textLayout.getLineTop(line).toFloat(),
                    clipRight,
                    textLayout.getLineBottom(line).toFloat(),
                )
                textLayout.draw(canvas)
                canvas.restore()
            }
        }

        /// 字符段末边界的 x 坐标。segEnd 恰为换行边界（== 前一字符所在行
        /// 的行末，且后面还有行）时，getPrimaryHorizontal 内部的
        /// getLineForOffset 会选中下一行并测得零宽，返回下一行行首的 x
        /// ——居中对齐下该值远在左侧，导致第一行最后一个词（中文歌词无
        /// 空格、断行常落在词尾）的扫光裁剪区永远盖不到词形。此时改取
        /// 该行最后一个字符的左边界 + 该字符宽度，即精确的行内容右缘。
        private fun segmentEndX(textLayout: Layout, segEnd: Int): Float {
            if (segEnd > 0) {
                val line = textLayout.getLineForOffset(segEnd - 1)
                if (line < textLayout.lineCount - 1 && segEnd == textLayout.getLineEnd(line)) {
                    return textLayout.getPrimaryHorizontal(segEnd - 1) +
                        paint.measureText(text, segEnd - 1, segEnd)
                }
            }
            return textLayout.getPrimaryHorizontal(segEnd)
        }

        /// 文本纵向落点：暗色与亮色两遍共用同一偏移，必然完全重合，
        /// 不存在重影；wrap_content 高度下即垂直居中。
        private fun verticalTextOffset(textLayout: Layout): Int =
            when (gravity and Gravity.VERTICAL_GRAVITY_MASK) {
                Gravity.BOTTOM -> (height - paddingBottom - textLayout.height)
                    .coerceAtLeast(paddingTop)
                Gravity.CENTER_VERTICAL -> ((height - textLayout.height) / 2)
                    .coerceAtLeast(paddingTop)
                else -> paddingTop
            }

        private fun dimColorOf(bright: Int): Int = Color.argb(
            (Color.alpha(bright) * .55f).toInt(),
            Color.red(bright),
            Color.green(bright),
            Color.blue(bright),
        )
    }
}
