package com.xymusic.mobile

import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.ColorDrawable
import android.media.AudioManager
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import android.text.Layout
import android.text.SpannableString
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.view.Choreographer
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.WindowManager
import android.view.MotionEvent
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.Space
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
    /** 暂停时隐藏歌词：开启且未在播放时隐藏歌词内容，恢复播放重新显示。 */
    val hideOnPause: Boolean,
    val effectMode: Int,
    val locked: Boolean,
    val noBackground: Boolean,
    val lyricColor: Int,
    val translationColor: Int,
    val lyricFontSize: Float,
    val translationFontSize: Float,
    val backgroundColor: Int,
    val backgroundOpacity: Float,
    /** 纵向位置（百分制）：0 = 屏幕最顶端、50 = 屏幕正中、100 = 屏幕最底端。 */
    val verticalPercent: Float,
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

        /** 浮窗默认纵向位置（百分制）：未设置过时的初始位置，靠近屏幕底部。 */
        const val DEFAULT_PERCENT = 90f

        /** 手动拖动结束后回传纵向位置（百分制），让设置页滑块跟随实际位置。
         * 不同步会发生「拖动后再收到一次旧滑块值 → 位置被拉回」的复位。 */
        @Volatile
        var positionReporter: ((Float) -> Unit)? = null

        /** 浮窗关闭按钮被点击后回调 Dart：同步关闭设置里的桌面歌词开关。
         * 浮窗已自行 stopSelf，这里只负责让设置页开关同步为关闭。 */
        @Volatile
        var closeReporter: (() -> Unit)? = null

        /** 操作栏 A-/A+ 调节字号后回传 Dart：设置页滑块与持久化跟随。 */
        @Volatile
        var fontSizeReporter: ((Float) -> Unit)? = null

        /** 操作栏锁定键切换后回传 Dart：设置页「锁定桌面歌词」开关跟随。 */
        @Volatile
        var lockedReporter: ((Boolean) -> Unit)? = null
        /** 操作栏播放三键：action=prev/playPause/next，经 MainActivity 转发
         * Dart 直接控制播放（系统 dispatchMediaKeyEvent 在部分 ROM 后台
         * 被静默丢弃，进程内通道最可靠）。 */
        var mediaKeyReporter: ((String) -> Unit)? = null

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
    private var controlBar: LinearLayout? = null
    private var overlayParams: WindowManager.LayoutParams? = null
    private var downX = 0f
    private var downY = 0f
    private var startX = 0
    private var startY = 0

    // ---- 位置与字体状态 ----
    /** 浮窗当前纵向位置（px，自屏幕顶边起算），由 [appliedPercent] 换算而来。 */
    private var baseY = 0
    /** 已应用到浮窗的纵向位置（百分制）：0 = 顶端、50 = 居中、100 = 底端。
     * 作为位置唯一真源，浮窗高度/整屏高度变化后都据此重算，不会漂移。 */
    private var appliedPercent = DEFAULT_PERCENT
    /** 已应用的自定义字体路径（空 = 系统默认），避免重复创建 Typeface。 */
    private var appliedFontPath: String? = null

    // ---- 锁定与字号（操作栏 ↔ Dart 设置双向同步） ----
    /** 浮窗侧锁定状态：锁定 = 禁止拖动并隐藏操作栏，长按歌词 600ms 解锁。 */
    private var localLocked = false
    /** 浮窗侧字号（sp）：操作栏 A-/A+ 即时应用，随后回传 Dart 持久化。 */
    private var localFontSize = 24f
    /** 浮窗操作后等待 Dart 回显的锁定值：回显到达前忽略 Dart 推来的
     * locked 值（Dart 写回有延迟，提前跟随会造成操作栏闪烁）。 */
    private var pendingLockedEcho: Boolean? = null
    /** 同上，A-/A+ 调节后的字号回显。 */
    private var pendingFontSizeEcho: Float? = null
    /** 锁定时长按解锁判定（非锁定态不用）。 */
    private var unlockRunnable: Runnable? = null

    /** 操作栏播放/暂停键：图标随播放状态动态切换（播放中=⏸、暂停=▶）。 */
    private var playKey: ImageView? = null
    private var lastPlayingIcon = true

    /** 操作栏与分隔线：默认隐藏，单击歌词行切换显隐。 */
    private var dividerRow: View? = null
    private var barVisible = false

    /// 按当前状态应用操作栏/分隔线可见性：锁定或未呼出时整体隐藏。
    private fun applyBarVisibility() {
        val visible = barVisible && !localLocked
        controlBar?.visibility = if (visible) View.VISIBLE else View.GONE
        dividerRow?.visibility = if (visible) View.VISIBLE else View.GONE
    }

    /// 单击歌词行：切换操作栏呼出/收起。
    private fun toggleControlBar() {
        barVisible = !barVisible
        applyBarVisibility()
    }

    /** 歌词内容层（承载背景色/圆角）。外层 root 只做容器，设在外层会被
     * 内容层自身背景盖住。 */
    private var panelContent: View? = null
    /** 是否正在手动拖动浮窗：拖动期间忽略按百分制重算位置（否则每 500ms
     * 的进度同步会把浮窗拉回上一次滑块刻度值，表现为「整十吸附」）。 */
    private var dragging = false

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

    /** 上次已应用的「暂停时隐藏歌词」状态（true 表示歌词内容处于隐藏态）。 */
    private var lastHideLyrics = false

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
        hideOnPause = intent.getBooleanExtra("hideOnPause", false),
        effectMode = intent.getIntExtra("wordEffectMode", EFFECT_NONE),
        locked = intent.getBooleanExtra("locked", false),
        noBackground = intent.getBooleanExtra("noBackground", true),
        lyricColor = intent.getIntExtra("lyricColor", 0xFFFFFFFF.toInt()),
        translationColor = intent.getIntExtra("translationColor", 0xFFE1E1E6.toInt()),
        lyricFontSize = intent.getFloatExtra("lyricFontSize", 24f),
        translationFontSize = intent.getFloatExtra("translationFontSize", 13f),
        backgroundColor = intent.getIntExtra("backgroundColor", 0xFF18181C.toInt()),
        backgroundOpacity = intent.getFloatExtra("backgroundOpacity", .85f),
        verticalPercent = intent.getFloatExtra("verticalPercent", DEFAULT_PERCENT),
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
            // 单行行高（对齐 QQ 音乐桌面歌词）：长句省略号截断，不换行。
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
            gravity = Gravity.CENTER
            textAlignment = View.TEXT_ALIGNMENT_CENTER
            setLineSpacing(0f, 1.2f)
            positionProvider = { currentRenderPosition() }
        }
        // 单行行高略微加高：歌词行上下各加 6dp 内边距，视觉更松弛、居中。
        val vPad = (6 * resources.displayMetrics.density).toInt()
        lyric.setPadding(0, vPad, 0, vPad)
        val density = resources.displayMetrics.density
        // 歌词行与操作栏之间的分隔线（细半透明白线，水平内缩居中）。
        val divider = View(this).apply {
            background = GradientDrawable().apply {
                setColor(Color.argb(55, 255, 255, 255))
                cornerRadius = 1f
            }
        }
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(28, 14, 28, 14)
            addView(lyric, LinearLayout.LayoutParams(-1, -2))
            addView(
                divider,
                LinearLayout.LayoutParams(-1, (1 * density).toInt()).apply {
                    setMargins((36 * density).toInt(), (7 * density).toInt(), (36 * density).toInt(), (7 * density).toInt())
                },
            )
            // 操作栏默认隐藏：单击歌词行切换显隐（见触摸 UP 分支）。
            addView(buildControlBar())
            background = GradientDrawable().apply {
                cornerRadius = 32f
                setColor(Color.argb(218, 24, 24, 28))
                setStroke(1, Color.argb(75, 255, 255, 255))
            }
        }
        lyricView = lyric
        controlBar =
            content.getChildAt(2) as? LinearLayout
        // 分隔线随操作栏一起显隐（包一层行容器控制 visibility 更稳）。
        dividerRow = content.getChildAt(1)
        applyBarVisibility()
        panelContent = content
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
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                // 让坐标空间覆盖状态栏：默认浮窗坐标区不含状态栏，导致歌词
                // 最多只能拖到状态栏下沿、顶不上去。
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        ).apply {
            // 纵向锚定在顶边：y 自屏幕顶边起算。行数变化（如长句换行）
            // 导致浮窗高度变化时，系统按 gravity 锚定的一侧先布局、
            // addOnLayoutChangeListener 再修正 y。锚定底边时浮窗「向上长」，
            // 顶边先冲出屏幕再被拉回，浮窗在顶部时表现为一次可见的跳动；
            // 锚定顶边则顶边天然不动、内容向下扩展，完全无跳动。
            gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            val prefs = getSharedPreferences("desktop_lyrics", MODE_PRIVATE)
            x = prefs.getInt("x", 0)
            // 恢复已应用的纵向位置：服务被回收重建时 Dart 会把当前滑块值
            // 再推一次，记住已应用值才不会造成位置跳变。
            appliedPercent = prefs.getFloat("percent", DEFAULT_PERCENT)
            baseY = clampY(percentToY(appliedPercent))
            y = baseY
        }
        overlayParams = params
        val touchSlop = android.view.ViewConfiguration.get(this).scaledTouchSlop
        content.setOnTouchListener { view, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = event.rawX
                    downY = event.rawY
                    startX = params.x
                    startY = baseY
                    if (localLocked) {
                        // 锁定态：长按 600ms 解锁（带震动反馈），期间忽略一切移动。
                        val runnable = Runnable {
                            unlockRunnable = null
                            setLocked(false)
                            vibrate()
                        }
                        unlockRunnable = runnable
                        view.postDelayed(runnable, 600)
                    } else {
                        // 进入拖动：期间忽略按百分制重算位置，保证拖动连续不吸附。
                        dragging = true
                    }
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    if (localLocked) {
                        if (abs(event.rawX - downX) > touchSlop ||
                            abs(event.rawY - downY) > touchSlop
                        ) {
                            cancelUnlock(view)
                        }
                        return@setOnTouchListener true
                    }
                    params.x = startX + (event.rawX - downX).toInt()
                    // 拖动直接写浮窗位置；拖动结束后再换算回百分制回传。
                    // 按整屏（含状态栏）高度钳制，允许一直拖到屏幕最顶端。
                    // y 自顶边起算，与屏幕方向一致：手指上移 → y 减小。
                    baseY = clampY(startY + (event.rawY - downY).toInt())
                    params.y = baseY
                    try {
                        windowManager?.updateViewLayout(view, params)
                    } catch (_: Exception) {
                        // 系统回收浮窗时忽略最后一次拖动。
                    }
                    true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    if (localLocked) {
                        cancelUnlock(view)
                        return@setOnTouchListener true
                    }
                    // 单击（位移在 slop 内）切换操作栏显隐；拖动结束照旧存位置。
                    val moved = abs(event.rawX - downX) > touchSlop ||
                        abs(event.rawY - downY) > touchSlop
                    if (!moved && event.actionMasked == MotionEvent.ACTION_UP) {
                        toggleControlBar()
                    }
                    // 先退出拖动态，后续同步即可按新的百分制值校正（值已一致）。
                    dragging = false
                    getSharedPreferences("desktop_lyrics", MODE_PRIVATE)
                        .edit()
                        .putInt("x", params.x)
                        .apply()
                    // 把拖动结果换算成纵向位置（百分制）回传 Dart：设置页滑块
                    // 跟随实际位置，且随后的更新不会再用旧滑块值把浮窗拉回去。
                    reportPercent()
                    true
                }
                else -> true
            }
        }
        // 浮窗首次测量/内容高度变化时重算 y：整屏钳制的上边界依赖浮窗
        // 实际高度，布局完成前拿不到，需在布局变化后补一次钳制。
        content.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
            applyWindowPosition()
        }
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        try {
            windowManager?.addView(content, params)
        } catch (_: Exception) {
            panel = null
            panelContent = null
            lyricView = null
            controlBar = null
            overlayParams = null
            stopSelf()
        }
    }

    /// 锁定态长按解锁的定时取消（移动超阈值或手指抬起）。
    private fun cancelUnlock(view: View) {
        unlockRunnable?.let { view.removeCallbacks(it) }
        unlockRunnable = null
    }

    /// 底部操作栏（一行 8 键）：播放三键 + 字号调节 + 锁定 + 设置 + 关闭。
    /// 样式对齐 MusicFree 桌面版：Material 线性图标键集中居中、小间距
    /// （字号键用 A−/A+ 文字）。锁定态整栏隐藏（只剩歌词行），长按解锁。
    private fun buildControlBar(): LinearLayout {
        val density = resources.displayMetrics.density
        fun icon(resId: Int, onClick: () -> Unit): ImageView =
            ImageView(this).apply {
                setImageResource(resId)
                val pad = (6 * density).toInt()
                setPadding(pad, pad, pad, pad)
                background = null
                setOnClickListener { onClick() }
            }
        fun textKey(label: String, onClick: () -> Unit): TextView =
            TextView(this).apply {
                text = label
                setTextColor(Color.WHITE)
                textSize = 13f
                gravity = Gravity.CENTER
                includeFontPadding = false
                typeface = Typeface.DEFAULT_BOLD
                val pad = (6 * density).toInt()
                setPadding(pad, pad, pad, pad)
                background = null
                // 与图标键同高（24dp 图标 + 6dp×2 内边距 = 36dp），八个键等高。
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    (36 * density).toInt(),
                )
                setOnClickListener { onClick() }
            }
        fun gapView(): View = Space(this).apply {
            layoutParams = LinearLayout.LayoutParams((4 * density).toInt(), 1)
        }
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            // 播放/暂停键：先创建并登记成员，再按当前状态放初始图标。
            val playButton = icon(R.drawable.ic_dlyr_pause) {
                sendMediaKey("playPause")
            }
            playKey = playButton
            // 播放三键（播放/暂停图标随状态动态切换，见 applyUpdate）
            addView(icon(R.drawable.ic_dlyr_prev) {
                sendMediaKey("prev")
            })
            addView(playButton)
            addView(icon(R.drawable.ic_dlyr_next) {
                sendMediaKey("next")
            })
            addView(gapView())
            // 字号调节（文字键）
            addView(textKey("A−") { adjustFontSize(-2f) })
            addView(textKey("A+") { adjustFontSize(2f) })
            addView(gapView())
            // 锁定 / 设置 / 关闭
            addView(icon(R.drawable.ic_dlyr_lock) { setLocked(true) })
            addView(icon(R.drawable.ic_dlyr_settings) { openSettings() })
            addView(icon(R.drawable.ic_dlyr_close) {
                closeReporter?.invoke()
                stopSelf()
            })
        }
    }

    /// 播放三键：走进程内 reporter → MainActivity → Dart（player_provider
    /// 直接控制播放）。系统 dispatchMediaKeyEvent 依赖「活跃媒体会话」路由，
    /// 在部分 ROM（澎湃/ColorOS 后台派发限制）会被静默丢弃导致按键无反应。
    private fun sendMediaKey(action: String) {
        mediaKeyReporter?.invoke(action)
    }

    /// A-/A+：字号即时应用 + 回传 Dart 持久化（设置页滑块跟随）。
    private fun adjustFontSize(delta: Float) {
        val target = (localFontSize + delta).coerceIn(16f, 40f)
        if (abs(target - localFontSize) < 0.1f) return
        localFontSize = target
        applyFontSize(target)
        pendingFontSizeEcho = target
        fontSizeReporter?.invoke(target)
    }

    /// 应用字号（sp）：与当前渲染值差 0.5px 内跳过，避免重复触发重排。
    private fun applyFontSize(sp: Float) {
        val view = lyricView ?: return
        val scaled = sp * resources.displayMetrics.scaledDensity
        if (abs(view.textSize - scaled) > .5f) view.textSize = sp
    }

    /// 锁定切换：隐藏/恢复操作栏 + 回传 Dart 同步设置页开关。
    private fun setLocked(value: Boolean) {
        localLocked = value
        pendingLockedEcho = value
        lockedReporter?.invoke(value)
        applyLockedState()
    }

    /// 锁定状态渲染：锁定时只剩歌词行。
    private fun applyLockedState() {
        // 锁定语义 = 禁拖 + 收起操作栏（长按解锁后恢复用户上次的呼出状态）。
        applyBarVisibility()
    }

    /// ⚙ 设置键：进入软件的桌面歌词设置页（MainActivity 转发 Dart 路由）。
    private fun openSettings() {
        val intent = Intent(this, MainActivity::class.java).apply {
            putExtra("open_desktop_lyrics_settings", true)
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP,
            )
        }
        try {
            startActivity(intent)
        } catch (_: Exception) {
            // 极端情况下 Activity 未导出（不应发生），忽略。
        }
    }

    /// 长按解锁的震动反馈（轻触感）。
    private fun vibrate() {
        try {
            val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val manager = getSystemService(VIBRATOR_MANAGER_SERVICE) as VibratorManager
                manager.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                getSystemService(VIBRATOR_SERVICE) as Vibrator
            }
            vibrator.vibrate(
                VibrationEffect.createOneShot(30, VibrationEffect.DEFAULT_AMPLITUDE),
            )
        } catch (_: Exception) {
            // 部分设备无震动器，忽略。
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

        // 暂停时隐藏歌词：开启且未在播放时隐藏整个浮窗（歌词/分隔线/
        // 操作栏/背景一体隐藏，只藏文本会留下空背景块悬浮在桌面上），
        // 恢复播放或关闭该选项后重新显示。
        val hideLyrics = p.hideOnPause && !p.isPlaying
        if (hideLyrics != lastHideLyrics) {
            lastHideLyrics = hideLyrics
            panelContent?.visibility =
                if (hideLyrics) View.GONE else View.VISIBLE
        }

        // 位置/字体类参数：纵向位置百分制、自定义字体。这些参数变化频率
        // 极低（仅用户调节时推送），每次更新时幂等应用即可。
        applyPercent(p.verticalPercent)
        applyFont(p.lyricFontPath)
        applyWindowPosition()

        // 锁定状态同步（浮窗操作栏 ↔ Dart 设置页双向）：
        // 浮窗操作后的回显到达前忽略 Dart 推来的值，避免操作栏闪烁。
        if (pendingLockedEcho != null) {
            if (p.locked == pendingLockedEcho) pendingLockedEcho = null
        } else if (p.locked != localLocked) {
            localLocked = p.locked
            applyLockedState()
        }

        // 播放/暂停键图标动态切换：播放中显示 ⏸（点按暂停），暂停显示 ▶。
        if (playKey != null && p.isPlaying != lastPlayingIcon) {
            lastPlayingIcon = p.isPlaying
            playKey?.setImageResource(
                if (p.isPlaying) R.drawable.ic_dlyr_pause else R.drawable.ic_dlyr_play,
            )
        }

        // 锁定不再使用 FLAG_NOT_TOUCHABLE 全窗穿透（那样长按解锁手势也
        // 收不到事件）；锁定语义 = 禁止拖动 + 隐藏操作栏，触摸仍由浮窗
        // 消费（锁定时长按 600ms 解锁）。
        overlayParams?.let { params ->
            val desiredFlags = WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN
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

        val contentKey = "$lyric\u0000${p.wordsJson}" +
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

        // 字号同步（浮窗 A-/A+ ↔ Dart 设置页滑块）：回显到达前忽略 Dart 值。
        // 暂停时隐藏歌词：主行一同隐藏（背景保留，浮窗仍可拖动）。
        val lyricFontSize = (pendingFontSizeEcho ?: p.lyricFontSize).coerceIn(16f, 40f)
        if (pendingFontSizeEcho != null &&
            abs(pendingFontSizeEcho!! - p.lyricFontSize) < 0.1f
        ) {
            pendingFontSizeEcho = null
        }
        lyricView?.let { view ->
            val desiredVisibility = if (hideLyrics) View.GONE else View.VISIBLE
            if (view.visibility != desiredVisibility) {
                view.visibility = desiredVisibility
            }
            if (abs(localFontSize - lyricFontSize) > 0.1f) {
                localFontSize = lyricFontSize
            }
            applyFontSize(localFontSize)
        }

        val backgroundKey = "${p.noBackground}|${p.backgroundColor}|${p.backgroundOpacity}"
        if (backgroundKey != lastBackgroundKey) {
            lastBackgroundKey = backgroundKey
            // 背景色设在歌词内容层：内容层自带一层深色背景，若设在外层
            // root 上会被内容层完全遮住，表现为「背景色设置不生效」。
            panelContent?.background = if (p.noBackground) {
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

    /** 整屏高度（含状态栏）：配合 FLAG_LAYOUT_IN_SCREEN 取真实显示尺寸，
     * 不用 Resources.displayMetrics（默认已扣掉系统栏，顶不到状态栏）。 */
    private fun screenHeightPx(): Int {
        val wm = windowManager ?: getSystemService(WINDOW_SERVICE) as WindowManager
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            wm.currentWindowMetrics.bounds.height()
        } else {
            val point = android.graphics.Point()
            @Suppress("DEPRECATION")
            wm.defaultDisplay.getRealSize(point)
            point.y
        }
    }

    /** 浮窗可移动的纵向范围（px）：整屏高度减去浮窗自身高度。 */
    private fun availableHeightPx(): Int {
        val panelHeight = panel?.height?.takeIf { it > 0 } ?: 0
        return (screenHeightPx() - panelHeight).coerceAtLeast(0)
    }

    /** 浮窗 y 钳制：y 自屏幕顶边起算，上限取「整屏高 - 浮窗高」，
     * 保证浮窗完整可见且能一直贴到屏幕最顶端（可覆盖状态栏）。 */
    private fun clampY(value: Int): Int = value.coerceIn(0, availableHeightPx())

    /** 百分制纵向位置 → 浮窗 y（px，自屏幕顶边起算）。
     * 0 = 屏幕最顶端（y=0，浮窗顶边贴屏顶）；100 = 屏幕最底端。 */
    private fun percentToY(percent: Float): Int {
        val available = availableHeightPx()
        return (available * (percent.coerceIn(0f, 100f) / 100f)).toInt()
    }

    /** 浮窗 y（px，自顶边起算）→ 百分制纵向位置，与 [percentToY] 互为反算。 */
    private fun yToPercent(y: Int): Float {
        val available = availableHeightPx()
        if (available <= 0) return appliedPercent
        return ((y.toFloat() / available) * 100f).coerceIn(0f, 100f)
    }

    /** 浮窗高度变化后重新按当前百分制位置摆放（可移动范围依赖浮窗高度）。
     * 手动拖动期间必须跳过：否则每 500ms 的进度同步会按「上一次已应用的
     * 百分制值」重算 y，把浮窗吸回滑块刻度（整十）位置。 */
    private fun applyWindowPosition() {
        if (dragging) return
        val params = overlayParams ?: return
        val target = clampY(percentToY(appliedPercent))
        if (params.y != target) {
            params.y = target
            baseY = target
            try {
                panel?.let { windowManager?.updateViewLayout(it, params) }
            } catch (_: Exception) {
                // 浮窗已被系统回收时忽略位置更新。
            }
        }
    }

    /** 应用设置页「上下位置」滑块（百分制）。
     *
     * 百分制是位置唯一真源、浮窗 y 始终由它换算，因此手动拖动后不会再被
     * 旧的绝对值重算拉回原位（旧实现按「滑块绝对值」反复平移导致复位）。 */
    private fun applyPercent(incomingPercent: Float) {
        val target = incomingPercent.coerceIn(0f, 100f)
        if (abs(target - appliedPercent) < 0.01f) return
        appliedPercent = target
        getSharedPreferences("desktop_lyrics", MODE_PRIVATE)
            .edit().putFloat("percent", appliedPercent).apply()
    }

    /** 手动拖动结束后，把浮窗实际位置换算成百分制回传 Dart：设置页滑块
     * 跟随实际位置，并作为后续更新的真源（避免拖动后被旧滑块值拉回）。 */
    private fun reportPercent() {
        val percent = yToPercent(baseY)
        if (abs(percent - appliedPercent) < 0.5f) return
        appliedPercent = percent
        getSharedPreferences("desktop_lyrics", MODE_PRIVATE)
            .edit().putFloat("percent", appliedPercent).apply()
        positionReporter?.invoke(percent)
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
        panelContent = null
        lyricView = null
        controlBar = null
        playKey = null
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
