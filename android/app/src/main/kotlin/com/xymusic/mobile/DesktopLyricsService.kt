package com.xymusic.mobile

import android.app.Service
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.ColorDrawable
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.text.SpannableString
import android.text.Spanned
import android.text.style.ForegroundColorSpan
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

    private var windowManager: WindowManager? = null
    private var panel: View? = null
    private var lyricView: TextView? = null
    private var translationView: TextView? = null
    private var overlayParams: WindowManager.LayoutParams? = null
    private var downX = 0f
    private var downY = 0f
    private var startX = 0
    private var startY = 0

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
            textSize = 13f
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
        val effectMode = intent.getIntExtra("wordEffectMode", 2)
        val wordsJson = intent.getStringExtra("wordsJson").orEmpty()
        lyricView?.setText(
            buildWordText(lyric, wordsJson, position, effectMode, lyricColor),
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
        val translationFontSize = intent.getFloatExtra("translationFontSize", 13f).coerceIn(10f, 28f)
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
    }

    private fun buildWordText(
        lyric: String,
        wordsJson: String,
        position: Double,
        effectMode: Int,
        lyricColor: Int,
    ): CharSequence {
        if (effectMode == 2 || wordsJson.isBlank() || lyric == "暂无歌词") return lyric
        return try {
            val words = JSONArray(wordsJson)
            if (words.length() == 0) return lyric
            val styled = SpannableString(lyric)
            var cursor = 0
            for (index in 0 until words.length()) {
                val word = words.optJSONObject(index) ?: continue
                val text = word.optString("text", "")
                if (text.isEmpty()) continue
                val start = lyric.indexOf(text, cursor)
                if (start < 0) continue
                val end = (start + text.length).coerceAtMost(lyric.length)
                cursor = end
                val wordStart = word.optDouble("start", 0.0)
                val wordEnd = word.optDouble("end", wordStart)
                val progress = when {
                    position <= wordStart -> 0.0
                    position >= wordEnd || wordEnd <= wordStart -> 1.0
                    else -> ((position - wordStart) / (wordEnd - wordStart))
                        .coerceIn(0.0, 1.0)
                }
                styled.setSpan(
                    ForegroundColorSpan(interpolateColor(lyricColor, progress)),
                    start,
                    end,
                    Spanned.SPAN_EXCLUSIVE_EXCLUSIVE,
                )
            }
            styled
        } catch (_: Exception) {
            lyric
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
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
