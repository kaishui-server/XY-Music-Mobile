package com.xymusic.mobile

import android.app.Service
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.ColorDrawable
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import android.provider.Settings
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

/** 系统级桌面歌词浮窗。只展示当前歌曲和当前时间点歌词，不抢占焦点。 */
class DesktopLyricsService : Service() {
    companion object {
        const val ACTION_SHOW = "com.xymusic.mobile.desktop_lyrics.SHOW"
        const val ACTION_UPDATE = "com.xymusic.mobile.desktop_lyrics.UPDATE"
        const val ACTION_STOP = "com.xymusic.mobile.desktop_lyrics.STOP"
    }

    /** 单个逐字片段在歌词文本中的区间与时间轴。 */
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

    // ---- 逐字渲染状态 ----
    // Dart 侧进度同步有 100ms 节流，直接按推送的 position 渲染会让逐字
    // 填充每 100~200ms 跳一格（明显卡顿）。原生侧保存最近一次 position
    // 与其到达时刻，用 Choreographer 每帧把播放位置按经过的墙钟时间前
    // 推，span 颜色连续插值，即可达到与播放页内嵌歌词同级的流畅度。
    private var wordSpans: List<WordSpan> = emptyList()
    private var wordColorSpans: Array<ForegroundColorSpan?> = emptyArray()
    private var wordText: SpannableString? = null
    private var lyricBaseColor = Color.WHITE
    private var basePosition = 0.0
    private var baseUptimeMs = 0L
    private var lyricsPlaying = false
    private var wordEffectMode = 2
    private var frameCallbackPosted = false
    private val frameCallback = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            frameCallbackPosted = false
            renderWordProgress()
            maybePostNextFrame()
        }
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
                updateText(intent)
            }
        }
        return START_STICKY
    }

    private fun canDrawOverlays(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(this)

    private fun ensurePanel() {
        if (panel != null) return
        val lyric = TextView(this).apply {
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
            y = prefs.getInt("y", 76)
        }
        overlayParams = params
        content.setOnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = event.rawX
                    downY = event.rawY
                    startX = params.x
                    startY = params.y
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    params.x = startX + (event.rawX - downX).toInt()
                    params.y = startY - (event.rawY - downY).toInt()
                    try {
                        windowManager?.updateViewLayout(content, params)
                    } catch (_: Exception) {
                        // 系统回收浮窗时忽略最后一次拖动。
                    }
                    true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    getSharedPreferences("desktop_lyrics", MODE_PRIVATE)
                        .edit()
                        .putInt("x", params.x)
                        .putInt("y", params.y)
                        .apply()
                    true
                }
                else -> true
            }
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

    private fun updateText(intent: Intent?) {
        if (intent == null) return
        val lyric = intent.getStringExtra("lyric").orEmpty().ifBlank { "暂无歌词" }
        translationView?.text = intent.getStringExtra("translation").orEmpty()
        val locked = intent.getBooleanExtra("locked", false)
        overlayParams?.let { params ->
            val desiredFlags = WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                if (locked) WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE else 0
            if (params.flags != desiredFlags) {
                params.flags = desiredFlags
                try {
                    panel?.let { windowManager?.updateViewLayout(it, params) }
                } catch (_: Exception) {
                    // 浮窗已被系统回收时忽略状态更新。
                }
            }
        }
        val lyricColor = intent.getIntExtra("lyricColor", Color.WHITE)
        val position = intent.getDoubleExtra("position", 0.0)
        val isPlaying = intent.getBooleanExtra("isPlaying", false)
        val effectMode = intent.getIntExtra("wordEffectMode", 2)
        val wordsJson = intent.getStringExtra("wordsJson").orEmpty()
        basePosition = position
        baseUptimeMs = SystemClock.elapsedRealtime()
        lyricsPlaying = isPlaying
        wordEffectMode = effectMode
        lyricBaseColor = lyricColor
        wordSpans = parseWordSpans(lyric, wordsJson, effectMode)
        wordColorSpans = arrayOfNulls(wordSpans.size)
        val styled = if (wordSpans.isEmpty()) {
            wordText = null
            null
        } else {
            buildWordStyledText(lyric)
        }
        lyricView?.setText(
            styled ?: lyric,
            TextView.BufferType.SPANNABLE,
        )
        lyricView?.setTextColor(lyricColor)
        val lyricFontSize = intent.getFloatExtra("lyricFontSize", 24f).coerceIn(16f, 40f)
        if (kotlin.math.abs(
                (lyricView?.textSize ?: 0f) -
                    lyricFontSize * resources.displayMetrics.scaledDensity,
            ) > .5f
        ) {
            lyricView?.textSize = lyricFontSize
        }
        intent.getIntExtra("translationColor", Color.argb(190, 225, 225, 230)).let {
            translationView?.setTextColor(it)
        }
        val translationFontSize = intent.getFloatExtra("translationFontSize", 12f).coerceIn(10f, 28f)
        if (kotlin.math.abs(
                (translationView?.textSize ?: 0f) -
                    translationFontSize * resources.displayMetrics.scaledDensity,
            ) > .5f
        ) {
            translationView?.textSize = translationFontSize
        }
        val noBackground = intent.getBooleanExtra("noBackground", true)
        val backgroundColor = intent.getIntExtra("backgroundColor", Color.rgb(24, 24, 28))
        val opacity = intent.getFloatExtra("backgroundOpacity", .85f).coerceIn(.1f, 1f)
        panel?.background = if (noBackground) {
            ColorDrawable(Color.TRANSPARENT)
        } else {
            GradientDrawable().apply {
                cornerRadius = 32f
                setColor(
                    Color.argb(
                        (opacity * 255).toInt(),
                        Color.red(backgroundColor),
                        Color.green(backgroundColor),
                        Color.blue(backgroundColor),
                    ),
                )
                setStroke(1, Color.argb(75, 255, 255, 255))
            }
        }
        maybePostNextFrame()
    }

    /// 解析逐字时间轴并拆成字符级 span：渐进填充（progressive）模式下
    /// 每个字符的时间在词内线性分布，帧循环里字符依次点亮，形成当前词
    /// 从左到右的扫过填充；逐词切换（wordByWord）模式下字符时间与整词
    /// 一致，保持整词跳变高亮。
    private fun parseWordSpans(
        lyric: String,
        wordsJson: String,
        effectMode: Int,
    ): List<WordSpan> {
        if (effectMode == 2 || wordsJson.isBlank() || lyric == "暂无歌词") {
            return emptyList()
        }
        return try {
            val words = JSONArray(wordsJson)
            if (words.length() == 0) return emptyList()
            val spans = ArrayList<WordSpan>(words.length() * 3)
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
                if (effectMode == 1 && timeEnd > timeStart && text.length > 1) {
                    // 渐进填充：字符时间在词时长内线性分布。
                    val perChar = (timeEnd - timeStart) / text.length
                    for (ci in 0 until text.length) {
                        val cs = start + ci
                        if (cs >= end) break
                        spans.add(
                            WordSpan(
                                cs,
                                cs + 1,
                                timeStart + perChar * ci,
                                timeStart + perChar * (ci + 1),
                            ),
                        )
                    }
                } else {
                    // 逐词切换（或单字符词）：整词共用同一时间轴。
                    spans.add(WordSpan(start, end, timeStart, timeEnd))
                }
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

    /// 帧循环主体：按前推后的播放位置更新每个词的颜色 span。
    /// 颜色未变化的词跳过 span 替换，未在演唱的行整帧零开销。
    private fun renderWordProgress() {
        val styled = wordText ?: return
        if (wordEffectMode == 2 || wordSpans.isEmpty()) return
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

    private fun wordProgress(span: WordSpan, position: Double): Double = when {
        position <= span.timeStart -> 0.0
        position >= span.timeEnd || span.timeEnd <= span.timeStart -> 1.0
        else -> ((position - span.timeStart) / (span.timeEnd - span.timeStart))
            .coerceIn(0.0, 1.0)
    }

    /// 播放中且处于逐字模式时保持每帧回调；暂停或无逐字数据时停止，
    /// 避免悬浮窗在后台白白占用 CPU。
    private fun maybePostNextFrame() {
        val animatable = lyricsPlaying && wordEffectMode != 2 && wordSpans.isNotEmpty()
        if (animatable && !frameCallbackPosted) {
            frameCallbackPosted = true
            Choreographer.getInstance().postFrameCallback(frameCallback)
        } else if (!animatable) {
            Choreographer.getInstance().removeFrameCallback(frameCallback)
            frameCallbackPosted = false
        }
    }

    private fun interpolateColor(color: Int, progress: Double): Int {
        val factor = .28 + .72 * progress
        return Color.argb(
            Color.alpha(color),
            (Color.red(color) * factor).toInt().coerceIn(0, 255),
            (Color.green(color) * factor).toInt().coerceIn(0, 255),
            (Color.blue(color) * factor).toInt().coerceIn(0, 255),
        )
    }

    override fun onDestroy() {
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
}
