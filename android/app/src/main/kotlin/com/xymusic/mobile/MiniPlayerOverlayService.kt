package com.xymusic.mobile

import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.PorterDuff
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.SeekBar
import android.widget.TextView
import androidx.core.graphics.drawable.RoundedBitmapDrawableFactory
import org.json.JSONArray
import kotlin.math.abs

/** 迷你播放器悬浮窗单次更新参数。MainActivity 通过
 * [MiniPlayerOverlayService.instance] 直连调用 applyUpdate，避免高频进度
 * 同步每次都走 startService 的 binder 往返。 */
class MiniPlayerUpdateParams(
    val title: String,
    val artist: String,
    val isPlaying: Boolean,
    val isLoading: Boolean,
    val positionMs: Long,
    val durationMs: Long,
    /** 0 = 列表循环、1 = 单曲循环、2 = 随机播放。 */
    val playMode: Int,
    /** 封面本地缓存文件绝对路径（空 = 显示占位音符）。 */
    val coverPath: String,
    /** 播放队列（JSON 数组，元素含 title/artist），仅变化时下发。 */
    val queueJson: String,
    val queueIndex: Int,
)

/** 系统级迷你播放器悬浮窗：封面/标题/歌手/可拖动进度条/五个按钮
 * （播放模式、上一首、播放暂停、下一首、播放列表）。
 *
 * 与画中画不同，悬浮窗是独立窗口，窗口内的按钮与进度条天然可点击。 */
class MiniPlayerOverlayService : Service() {
    companion object {
        const val ACTION_SHOW = "com.xymusic.mobile.mini_player.SHOW"
        const val ACTION_UPDATE = "com.xymusic.mobile.mini_player.UPDATE"
        const val ACTION_STOP = "com.xymusic.mobile.mini_player.STOP"

        /** 与 Dart 侧约定的动作名，回传到播放层执行。 */
        const val ACTION_PREV = "previous"
        const val ACTION_TOGGLE = "toggle"
        const val ACTION_NEXT = "next"
        const val ACTION_CYCLE_MODE = "cyclePlayMode"
        const val ACTION_SEEK = "seek"
        const val ACTION_PLAY_INDEX = "playIndex"

        /** 运行中的服务实例，供 MainActivity 直连分发 update。 */
        @Volatile
        var instance: MiniPlayerOverlayService? = null

        /** 按钮/进度条操作回传 Dart：首个参数为动作名，第二个为数值
         * （seek = 毫秒、playIndex = 队列下标，其余为 0）。 */
        @Volatile
        var actionReporter: ((String, Double) -> Unit)? = null

        /** 关闭按钮被点击后回调 Dart：同步关闭设置里的迷你播放器开关。 */
        @Volatile
        var closeReporter: (() -> Unit)? = null

        /** 主题强调色（与 App 默认强调色一致）。 */
        private const val ACCENT = 0xFFEC4141.toInt()
        private const val TEXT_PRIMARY = 0xFF1A1A1E.toInt()
        private const val TEXT_SECONDARY = 0xFF8A8A90.toInt()
    }

    private var windowManager: WindowManager? = null
    private var root: View? = null
    private var card: View? = null
    private var overlayParams: WindowManager.LayoutParams? = null

    // ---- 视图引用 ----
    private var playerPane: View? = null
    private var queuePane: View? = null
    private var emptyPane: View? = null
    private var titleView: TextView? = null
    private var artistView: TextView? = null
    private var coverView: ImageView? = null
    private var seekBar: SeekBar? = null
    private var currentTimeView: TextView? = null
    private var totalTimeView: TextView? = null
    private var modeView: ImageView? = null
    private var playPauseView: ImageView? = null
    private var queueList: LinearLayout? = null
    private var queueItemViews: MutableList<QueueItemViews> = mutableListOf()

    private class QueueItemViews(
        val index: TextView,
        val title: TextView,
        val artist: TextView,
    )

    // ---- 播放状态缓存（增量更新，避免每次同步全量重建视图）----
    private var playing = false
    private var loading = false
    private var durationMs = 0L
    private var basePositionMs = 0L
    private var baseUptimeMs = 0L
    private var playMode = 0
    private var queueIndex = -1
    private var lastQueueJson: String? = null
    private var lastModeKey: Int? = null
    private var lastPlayKey: Boolean? = null
    private var lastTitle: String? = null
    private var lastArtist: String? = null
    private var lastDurationMs = -1L
    private var coverRequestSeq = 0
    private var loadedCoverPath: String? = null

    // ---- 拖动与进度拖动状态 ----
    private var draggingWindow = false
    private var draggingSeek = false
    private var downX = 0f
    private var downY = 0f
    private var startX = 0
    private var startY = 0

    private val uiHandler = Handler(Looper.getMainLooper())
    private val progressTicker = object : Runnable {
        override fun run() {
            tickProgress()
            if (playing && !draggingSeek) uiHandler.postDelayed(this, 500)
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onDestroy() {
        instance = null
        uiHandler.removeCallbacks(progressTicker)
        root?.let { view ->
            try {
                windowManager?.removeView(view)
            } catch (_: Exception) {
                // 浮窗已被系统回收。
            }
        }
        root = null
        card = null
        overlayParams = null
        playerPane = null
        queuePane = null
        emptyPane = null
        titleView = null
        artistView = null
        coverView = null
        seekBar = null
        currentTimeView = null
        totalTimeView = null
        modeView = null
        playPauseView = null
        queueList = null
        queueItemViews = mutableListOf()
        super.onDestroy()
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

    override fun onBind(intent: Intent?): IBinder? = null

    private fun canDrawOverlays(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(this)

    private fun paramsFromIntent(intent: Intent) = MiniPlayerUpdateParams(
        title = intent.getStringExtra("title").orEmpty(),
        artist = intent.getStringExtra("artist").orEmpty(),
        isPlaying = intent.getBooleanExtra("isPlaying", false),
        isLoading = intent.getBooleanExtra("isLoading", false),
        positionMs = intent.getLongExtra("positionMs", 0L),
        durationMs = intent.getLongExtra("durationMs", 0L),
        playMode = intent.getIntExtra("playMode", 0),
        coverPath = intent.getStringExtra("coverPath").orEmpty(),
        queueJson = intent.getStringExtra("queueJson").orEmpty(),
        queueIndex = intent.getIntExtra("queueIndex", -1),
    )

    // ---------------------------------------------------------------- 视图搭建

    private fun dp(value: Float): Int =
        (value * resources.displayMetrics.density + .5f).toInt()

    private fun ensurePanel() {
        if (root != null) return

        val title = TextView(this).apply {
            setTextColor(TEXT_PRIMARY)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            gravity = Gravity.CENTER
            maxLines = 2
            ellipsize = android.text.TextUtils.TruncateAt.END
        }
        val artist = TextView(this).apply {
            setTextColor(TEXT_SECONDARY)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            gravity = Gravity.CENTER
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
        }
        val cover = ImageView(this).apply {
            scaleType = ImageView.ScaleType.CENTER_CROP
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(0xFFF1F1F4.toInt())
            }
            setImageResource(R.drawable.xy_ic_music_note)
            setColorFilter(0xFFC9C9D0.toInt(), PorterDuff.Mode.SRC_IN)
        }
        val coverWrap = FrameLayout(this).apply {
            addView(
                cover,
                FrameLayout.LayoutParams(dp(160f), dp(160f), Gravity.CENTER),
            )
        }
        val seek = SeekBar(this).apply {
            max = 1000
            progress = 0
            progressDrawable?.setColorFilter(ACCENT, PorterDuff.Mode.SRC_IN)
            thumb?.setColorFilter(ACCENT, PorterDuff.Mode.SRC_IN)
            splitTrack = false
        }
        val currentTime = timeText()
        val totalTime = timeText().apply { gravity = Gravity.END }

        val timeRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(currentTime, LinearLayout.LayoutParams(0, -2, 1f))
            addView(totalTime, LinearLayout.LayoutParams(0, -2, 1f))
        }

        val mode = iconButton(R.drawable.xy_ic_repeat, TEXT_PRIMARY) {
            reportAction(ACTION_CYCLE_MODE, 0.0)
        }
        val prev = iconButton(R.drawable.xy_ic_prev, TEXT_PRIMARY) {
            reportAction(ACTION_PREV, 0.0)
        }
        val playPause = iconButton(R.drawable.xy_ic_play, TEXT_PRIMARY) {
            if (!loading) reportAction(ACTION_TOGGLE, 0.0)
        }
        val next = iconButton(R.drawable.xy_ic_next, TEXT_PRIMARY) {
            reportAction(ACTION_NEXT, 0.0)
        }
        val queueButton = iconButton(R.drawable.xy_ic_queue, TEXT_PRIMARY) {
            showQueuePane(true)
        }
        val buttonRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            for (button in listOf(mode, prev, playPause, next, queueButton)) {
                addView(button, LinearLayout.LayoutParams(0, dp(42f), 1f))
            }
        }

        val player = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(title, LinearLayout.LayoutParams(-1, -2))
            addView(
                artist,
                LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(4f) },
            )
            addView(
                coverWrap,
                LinearLayout.LayoutParams(-1, dp(168f)).apply { topMargin = dp(10f) },
            )
            addView(seek, LinearLayout.LayoutParams(-1, -2))
            addView(timeRow, LinearLayout.LayoutParams(-1, -2))
            addView(
                buttonRow,
                LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(2f) },
            )
        }

        // 播放列表页：就地展开队列，点选任意一首直接切歌。
        val queueHeader = TextView(this).apply {
            text = "播放列表"
            setTextColor(TEXT_PRIMARY)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        }
        val queueBack = TextView(this).apply {
            text = "收起"
            setTextColor(ACCENT)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            setPadding(dp(10f), dp(6f), dp(4f), dp(6f))
            setOnClickListener { showQueuePane(false) }
        }
        val headerRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(queueHeader, LinearLayout.LayoutParams(0, -2, 1f))
            addView(queueBack, LinearLayout.LayoutParams(-2, -2))
        }
        val list = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }
        val scroll = ScrollView(this).apply {
            isFillViewport = false
            addView(list, ViewGroup.LayoutParams(-1, -2))
        }
        val queue = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            visibility = View.GONE
            addView(headerRow, LinearLayout.LayoutParams(-1, -2))
            addView(
                scroll,
                LinearLayout.LayoutParams(-1, dp(232f)).apply { topMargin = dp(6f) },
            )
        }

        val empty = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            visibility = View.GONE
            addView(
                TextView(this@MiniPlayerOverlayService).apply {
                    text = "暂无播放"
                    setTextColor(TEXT_SECONDARY)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                    gravity = Gravity.CENTER
                },
                LinearLayout.LayoutParams(-1, -2),
            )
        }

        val cardView = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16f), dp(14f), dp(16f), dp(12f))
            background = GradientDrawable().apply {
                cornerRadius = dp(18f).toFloat()
                setColor(Color.WHITE)
                setStroke(dp(1f), 0x1A000000)
            }
            addView(player, LinearLayout.LayoutParams(-1, -2))
            addView(queue, LinearLayout.LayoutParams(-1, -2))
            addView(empty, LinearLayout.LayoutParams(-1, -2))
        }

        // 关闭按钮：常驻卡片右上角，点击移除浮窗并同步关闭设置开关。
        val close = TextView(this).apply {
            text = "×"
            setTextColor(TEXT_SECONDARY)
            textSize = 16f
            gravity = Gravity.CENTER
            includeFontPadding = false
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(0xFFF1F1F4.toInt())
            }
            setOnClickListener {
                closeReporter?.invoke()
                stopSelf()
            }
        }

        val rootView = FrameLayout(this).apply {
            setPadding(dp(10f), dp(10f), dp(10f), dp(10f))
            addView(
                cardView,
                FrameLayout.LayoutParams(dp(288f), -2, Gravity.CENTER_HORIZONTAL),
            )
            addView(
                close,
                FrameLayout.LayoutParams(dp(22f), dp(22f), Gravity.TOP or Gravity.END)
                    .apply {
                        topMargin = dp(16f)
                        rightMargin = dp(16f)
                    },
            )
        }

        titleView = title
        artistView = artist
        coverView = cover
        seekBar = seek
        currentTimeView = currentTime
        totalTimeView = totalTime
        modeView = mode
        playPauseView = playPause
        queueList = list
        playerPane = player
        queuePane = queue
        emptyPane = empty
        card = cardView
        root = rootView

        wireSeekBar(seek)
        wireDrag(rootView, cardView)

        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            val prefs = getSharedPreferences("mini_player", MODE_PRIVATE)
            x = prefs.getInt("x", dp(24f))
            y = prefs.getInt("y", dp(120f))
        }
        overlayParams = params
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        try {
            windowManager?.addView(rootView, params)
        } catch (_: Exception) {
            root = null
            card = null
            overlayParams = null
            stopSelf()
        }
    }

    private fun timeText(): TextView = TextView(this).apply {
        setTextColor(TEXT_SECONDARY)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
        text = "00:00"
    }

    /** 按钮图标：无背景、无内置 tint，按需 setColorFilter 着色。 */
    private fun iconButton(iconRes: Int, color: Int, onClick: () -> Unit): ImageView =
        ImageView(this).apply {
            setImageResource(iconRes)
            setColorFilter(color, PorterDuff.Mode.SRC_IN)
            scaleType = ImageView.ScaleType.CENTER
            val pad = dp(10f)
            setPadding(pad, pad, pad, pad)
            isClickable = true
            setOnClickListener { onClick() }
        }

    private fun wireSeekBar(seek: SeekBar) {
        seek.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(bar: SeekBar?, progress: Int, fromUser: Boolean) {
                if (!fromUser) return
                // 拖动中本地预览时间，松手才真正 seek。
                currentTimeView?.text = fmt((durationMs * progress / 1000.0).toLong())
            }

            override fun onStartTrackingTouch(bar: SeekBar?) {
                draggingSeek = true
                uiHandler.removeCallbacks(progressTicker)
            }

            override fun onStopTrackingTouch(bar: SeekBar?) {
                draggingSeek = false
                val progress = bar?.progress ?: 0
                if (durationMs > 0) {
                    reportAction(ACTION_SEEK, (durationMs * progress / 1000.0))
                }
                if (playing) uiHandler.removeCallbacks(progressTicker)
                uiHandler.postDelayed(progressTicker, 500)
            }
        })
    }

    /** 卡片空白区域可拖动整窗；子 View（按钮/滑块）自行消费触摸，
     * 因此按钮与进度条天然可点击。 */
    private fun wireDrag(rootView: View, cardView: View) {
        val slop = ViewConfiguration.get(this).scaledTouchSlop
        cardView.setOnTouchListener { _, event ->
            val params = overlayParams ?: return@setOnTouchListener false
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = event.rawX
                    downY = event.rawY
                    startX = params.x
                    startY = params.y
                    draggingWindow = true
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    if (!draggingWindow) return@setOnTouchListener true
                    if (abs(event.rawX - downX) < slop && abs(event.rawY - downY) < slop) {
                        return@setOnTouchListener true
                    }
                    params.x = startX + (event.rawX - downX).toInt()
                    params.y = (startY + (event.rawY - downY).toInt()).coerceAtLeast(0)
                    try {
                        windowManager?.updateViewLayout(rootView, params)
                    } catch (_: Exception) {
                        // 浮窗被系统回收时忽略最后一次拖动。
                    }
                    true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    if (draggingWindow) {
                        draggingWindow = false
                        getSharedPreferences("mini_player", MODE_PRIVATE)
                            .edit()
                            .putInt("x", params.x)
                            .putInt("y", params.y)
                            .apply()
                    }
                    true
                }
                else -> false
            }
        }
    }

    private fun showQueuePane(show: Boolean) {
        playerPane?.visibility = if (show) View.GONE else View.VISIBLE
        queuePane?.visibility = if (show) View.VISIBLE else View.GONE
    }

    // ---------------------------------------------------------------- 更新入口

    /** 统一更新入口（直连与 Intent 两条路径共用）。幂等：内容未变化时
     * 只做进度校正，不重建视图。 */
    fun applyUpdate(p: MiniPlayerUpdateParams) {
        if (!canDrawOverlays()) {
            stopSelf()
            return
        }
        ensurePanel()
        val hasSong = p.title.isNotBlank()
        playerPane?.visibility = if (hasSong) View.VISIBLE else View.GONE
        emptyPane?.visibility = if (hasSong) View.GONE else View.VISIBLE
        if (!hasSong) {
            playing = false
            uiHandler.removeCallbacks(progressTicker)
            return
        }

        if (lastTitle != p.title) {
            lastTitle = p.title
            titleView?.text = p.title
        }
        if (lastArtist != p.artist) {
            lastArtist = p.artist
            artistView?.text = p.artist
            artistView?.visibility = if (p.artist.isBlank()) View.GONE else View.VISIBLE
        }
        applyCover(p.coverPath)

        durationMs = p.durationMs.coerceAtLeast(0L)
        if (lastDurationMs != durationMs) {
            lastDurationMs = durationMs
            totalTimeView?.text = fmt(durationMs)
        }

        val modeKey = p.playMode
        if (lastModeKey != modeKey) {
            lastModeKey = modeKey
            playMode = modeKey
            modeView?.setImageResource(
                when (modeKey) {
                    1 -> R.drawable.xy_ic_repeat_one
                    2 -> R.drawable.xy_ic_shuffle
                    else -> R.drawable.xy_ic_repeat
                },
            )
            modeView?.setColorFilter(TEXT_PRIMARY, PorterDuff.Mode.SRC_IN)
        }

        loading = p.isLoading
        playing = p.isPlaying
        val playKey = p.isPlaying
        if (lastPlayKey != playKey || playPauseView?.tag == null) {
            lastPlayKey = playKey
            playPauseView?.setImageResource(
                if (playKey) R.drawable.xy_ic_pause else R.drawable.xy_ic_play,
            )
            playPauseView?.setColorFilter(TEXT_PRIMARY, PorterDuff.Mode.SRC_IN)
            playPauseView?.tag = "set"
        }

        // 进度基准：Dart 推来的 position 作为锚点，帧间由 ticker 前推。
        basePositionMs = p.positionMs.coerceIn(0L, if (durationMs > 0) durationMs else Long.MAX_VALUE)
        baseUptimeMs = SystemClock.elapsedRealtime()
        if (!draggingSeek) applyProgressUi(basePositionMs)

        if (p.queueJson.isNotEmpty() && p.queueJson != lastQueueJson) {
            lastQueueJson = p.queueJson
            rebuildQueue(p.queueJson)
        }
        if (queueIndex != p.queueIndex) {
            queueIndex = p.queueIndex
            highlightQueueIndex(queueIndex)
        }

        uiHandler.removeCallbacks(progressTicker)
        if (playing && !draggingSeek) uiHandler.postDelayed(progressTicker, 500)
    }

    private fun tickProgress() {
        if (!playing || draggingSeek || durationMs <= 0L) return
        val elapsed = SystemClock.elapsedRealtime() - baseUptimeMs
        val position = (basePositionMs + elapsed).coerceIn(0L, durationMs)
        applyProgressUi(position)
    }

    private fun applyProgressUi(positionMs: Long) {
        currentTimeView?.text = fmt(positionMs)
        val progress = if (durationMs > 0L) {
            (positionMs * 1000.0 / durationMs).toInt().coerceIn(0, 1000)
        } else {
            0
        }
        if (seekBar?.progress != progress) seekBar?.progress = progress
    }

    // ---------------------------------------------------------------- 封面与队列

    private fun applyCover(path: String) {
        if (path == loadedCoverPath) return
        loadedCoverPath = path
        val seq = ++coverRequestSeq
        val view = coverView ?: return
        if (path.isEmpty()) {
            view.setImageResource(R.drawable.xy_ic_music_note)
            view.setColorFilter(0xFFC9C9D0.toInt(), PorterDuff.Mode.SRC_IN)
            return
        }
        Thread {
            val bitmap: Bitmap? = try {
                BitmapFactory.decodeFile(path)
            } catch (_: Throwable) {
                null
            }
            uiHandler.post {
                if (seq != coverRequestSeq) {
                    bitmap?.recycle()
                    return@post
                }
                if (bitmap != null) {
                    coverView?.clearColorFilter()
                    coverView?.setImageDrawable(
                        RoundedBitmapDrawableFactory.create(resources, bitmap).apply {
                            isCircular = true
                        },
                    )
                } else {
                    coverView?.setImageResource(R.drawable.xy_ic_music_note)
                    coverView?.setColorFilter(0xFFC9C9D0.toInt(), PorterDuff.Mode.SRC_IN)
                }
            }
        }.start()
    }

    private fun rebuildQueue(json: String) {
        val list = queueList ?: return
        list.removeAllViews()
        queueItemViews = mutableListOf()
        val array = try {
            JSONArray(json)
        } catch (_: Exception) {
            JSONArray()
        }
        if (array.length() == 0) {
            list.addView(
                TextView(this).apply {
                    text = "列表为空"
                    setTextColor(TEXT_SECONDARY)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                    gravity = Gravity.CENTER
                    setPadding(0, dp(16f), 0, dp(16f))
                },
                LinearLayout.LayoutParams(-1, -2),
            )
            return
        }
        for (index in 0 until array.length()) {
            val item = array.optJSONObject(index) ?: continue
            val indexView = TextView(this).apply {
                text = "${index + 1}"
                setTextColor(TEXT_SECONDARY)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
                gravity = Gravity.CENTER
                width = dp(26f)
            }
            val titleView = TextView(this).apply {
                text = item.optString("title", "")
                setTextColor(TEXT_PRIMARY)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                maxLines = 1
                ellipsize = android.text.TextUtils.TruncateAt.END
            }
            val artistText = item.optString("artist", "")
            val artistView = TextView(this).apply {
                text = artistText
                setTextColor(TEXT_SECONDARY)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
                maxLines = 1
                ellipsize = android.text.TextUtils.TruncateAt.END
            }
            val column = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                addView(titleView, LinearLayout.LayoutParams(-1, -2))
                if (artistText.isNotBlank()) {
                    addView(artistView, LinearLayout.LayoutParams(-1, -2))
                }
            }
            val row = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(2f), dp(7f), dp(6f), dp(7f))
                isClickable = true
                addView(indexView, LinearLayout.LayoutParams(dp(26f), -2))
                addView(column, LinearLayout.LayoutParams(0, -2, 1f))
                setOnClickListener {
                    reportAction(ACTION_PLAY_INDEX, index.toDouble())
                    showQueuePane(false)
                }
            }
            list.addView(row, LinearLayout.LayoutParams(-1, -2))
            queueItemViews.add(QueueItemViews(indexView, titleView, artistView))
        }
        highlightQueueIndex(queueIndex)
    }

    private fun highlightQueueIndex(index: Int) {
        queueItemViews.forEachIndexed { i, views ->
            val active = i == index
            views.title.setTextColor(if (active) ACCENT else TEXT_PRIMARY)
            views.title.typeface = Typeface.create(
                Typeface.DEFAULT,
                if (active) Typeface.BOLD else Typeface.NORMAL,
            )
            views.index.setTextColor(if (active) ACCENT else TEXT_SECONDARY)
        }
    }

    private fun reportAction(action: String, value: Double) {
        actionReporter?.invoke(action, value)
    }

    private fun fmt(ms: Long): String {
        if (ms <= 0L) return "00:00"
        val total = (ms / 1000L).toInt()
        val minutes = total / 60
        val seconds = total % 60
        return String.format("%02d:%02d", minutes, seconds)
    }
}