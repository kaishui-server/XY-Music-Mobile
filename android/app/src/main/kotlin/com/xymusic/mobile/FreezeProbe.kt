package com.xymusic.mobile

import android.app.Activity
import android.app.ActivityManager
import android.app.Application
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.os.Debug
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import java.io.File
import java.io.RandomAccessFile
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 久播卡死诊断探针（原生侧，独立线程）。
 *
 * 卡死现场没有崩溃文件 → 不是 Java/Kotlin 未捕获异常。进程消失只有两种
 * 可能：被系统杀死（LMK/OOM）或原生崩溃（SIGSEGV/SIGABRT，不经过
 * UncaughtExceptionHandler），两者都不会留下崩溃文件。为了在进程再次
 * 死亡时能拿到可事后分析的证据，这里在独立线程上长期采集：
 *
 * 1. 上次进程退出原因：Android 11+ 的
 *    [ActivityManager.getHistoricalProcessExitReasons] 会给出系统记录的
 *    退出原因（LOW_MEMORY / CRASH_NATIVE / ANR / SIGNALED…），启动时写一条，
 *    直接回答"进程上一次是怎么死的"。
 * 2. 主线程调度延迟：向主 Looper 投递空 Runnable，测量回调延迟；持续偏大
 *    说明主线程被长任务卡住（界面冻结但进程未死的情形）。
 * 3. Dart 主 isolate 是否停摆：由 Dart 侧每次 audioProbe 调用时间推算。
 * 4. 进程内存（PSS）与系统可用内存趋势：判断是否为内存泄漏导致的 OOM 击杀。
 *
 * 采集全部在独立 HandlerThread 完成，不占用主线程与 Flutter isolate。
 *
 * 落盘策略：正常运行时采样只留在内存环形缓冲里，**不写文件**；只有真正
 * 命中异常（主线程长时间卡顿 / Dart isolate 停摆 / 内存或线程数持续暴涨）才把
 * 最近一段现场一次性写入 <filesDir>/xy_music/crash/crash-freeze.txt。这样
 * 「软件没崩溃却总有一份崩溃记录」的误报消失，而真卡死时仍能拿到卡死前
 * 的现场。文件名以 crash- 开头，会被「日志-崩溃记录」导出自动收录。
 *
 * 防误报：内存/线程两类指标极易被瞬时尖峰误导——启动初始化会把线程数顶到
 * ~160，zram 换入换出会让 pvDirty/pss2 在 10s 内在 3GB 与 200MB 间跳变。
 * 因此这两类要求「启动静默期之外 + 连续多次命中」，而 ActivityManager 的
 * totalPss 在部分 MIUI/ColorOS 机型上被缓存成常量，直接弃用（只看 smaps_rollup
 * 实测的 pss2，并要求系统可用内存同步见底）。
 */
object FreezeProbe {
    /** 采样间隔。 */
    private const val INTERVAL_MS = 10_000L

    /** 主线程延迟超过该值记一条事件。 */
    private const val MAIN_LAG_EVENT_MS = 8_000L

    /**
     * Dart 探针超过该值未刷新即判定 Dart 主 isolate 停摆。
     *
     * 【口径修正】必须显著大于 Dart 侧播放心跳周期（player_provider 的
     * _playerHeartbeatTimer = 20s）。早先取 20_000 恰好等于一个心跳周期，
     * 只要错开一拍（切前后台、暂停、切歌间隙、一次长 GC）就必然触发：
     * 荣耀 AAP-AN00 实测 20144ms / 20284ms 两条「停摆」即为此误报，
     * 当时 mainLag 全程 0~1ms、探针自身连续采样，进程根本没冻结。
     * 取 3 个心跳周期（60s）留足余量。
     */
    private const val DART_LAG_EVENT_MS = 60_000L

    /** 进程 PSS 超过该值、且系统可用内存见底，才判定内存异常。 */
    private const val MEMORY_EVENT_MB = 2048L

    /** 系统可用内存低于该值视为内存压力（与 MEMORY_EVENT_MB 同时满足才算异常）。 */
    private const val MEMORY_SYS_FLOOR_MB = 1024L

    /** 线程数超过该值即判定线程泄漏（正常播放约 80，启动初始化瞬时约 160）。 */
    private const val THREAD_EVENT_COUNT = 200

    /**
     * 进程启动后的静默期：Flutter 引擎/音频/Rust 初始化会瞬时抬高线程数与内存，
     * 这段时间只采样、不判定内存/线程异常，避免「一启动就有一份崩溃记录」。
     */
    private const val STARTUP_GRACE_MS = 120_000L

    /**
     * 内存/线程异常需「连续命中」的采样次数（10s 一次，即持续 30s）才落盘。
     * 启动尖峰、zram 换入换出都只让单次采样瞬时冲高，持续异常才是真问题。
     */
    private const val ANOMALY_STREAK = 3

    /** 冻结日志最多保留的行数（约 50 分钟历史）。 */
    private const val MAX_LINES = 320

    /** 异常现场内存环形缓冲行数（约 6 分钟）。 */
    private const val RING_SIZE = 36

    /** 每追加这么多行做一次裁剪。 */
    private const val TRIM_EVERY = 20

    private const val FILE_NAME = "crash-freeze.txt"

    private val timeFormat = SimpleDateFormat("HH:mm:ss", Locale.US)
    private val dateTimeFormat = SimpleDateFormat("MM-dd HH:mm:ss", Locale.US)

    @Volatile
    private var started = false

    /** 最近一次 Dart 侧 audioProbe 调用的时刻（uptimeMillis）。 */
    @Volatile
    private var lastDartProbeAt = 0L

    /**
     * 最近一次 Dart 侧「主动声明不探测」的原因（后台/暂停/无音源/重建中）。
     *
     * 早先只有 audioProbe 一种心跳，而 Dart 播放心跳在三处早退
     * （非 resumed、current==null、!isPlaying）时根本不会发 probe，于是
     * 停止观测被误判成「isolate 停摆」。让 Dart 把「我不探测」也上报一次，
     * 时间戳照常刷新——能上报本身就证明「Dart 事件循环 + 原生主线程都活着」，
     * 语义完全等价，只是原因不同。
     */
    @Volatile
    private var lastDartIdleReason: String = ""

    /** 上一个采样周期的投递时刻，用于自证「探针自身是否被系统冻结」。 */
    @Volatile
    private var lastSampleAt = 0L

    /** 最近一次测得的主线程延迟（ms）。 */
    @Volatile
    private var lastMainLagMs = 0L

    /** 前台可见 Activity 计数（>0 即前台），用于区分「后台被系统冻结」与「前台真停摆」。 */
    @Volatile
    private var foregroundActivities = 0

    private val lifecycleTracker = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityResumed(activity: Activity) {
            foregroundActivities++
        }

        override fun onActivityPaused(activity: Activity) {
            if (foregroundActivities > 0) foregroundActivities--
        }

        override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
        override fun onActivityStarted(activity: Activity) {}
        override fun onActivityStopped(activity: Activity) {}
        override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
        override fun onActivityDestroyed(activity: Activity) {}
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val lock = Any()
    private var logFile: File? = null
    private var appendCount = 0

    /** 采样次数，用于控制「最大区域明细」的落盘频率（解析整份 smaps 较贵）。 */
    private var sampleCount = 0L

    /** 探针启动时刻（≈ 进程启动），用于启动静默期判定。 */
    private var startedAtMs = 0L

    /** 内存/线程异常连续命中计数（掉出阈值即清零）。 */
    private var memoryStreak = 0
    private var threadStreak = 0

    /** 首次判定停摆时是否已落盘线程状态快照（只落一次，避免刷屏）。 */
    private var threadDumpDone = false

    /** 后台停摆提示行是否已记过（每段停摆只记一条，避免刷屏）。 */
    private var bgStallNoted = false

    /** 正常采样行的内存环形缓冲：命中异常时整段刷盘还原卡死过程。 */
    private val ring = ArrayDeque<String>()
    private var headerLines: List<String> = emptyList()
    private var flushed = false

    fun start(context: Context) {
        if (started) return
        started = true
        startedAtMs = SystemClock.uptimeMillis()
        val app = context.applicationContext
        logFile = File(CrashHandler.crashDir(app), FILE_NAME)
        // 前后台判定：后台被 MagicOS/ColorOS 等冻结 Dart isolate 属正常
        // 省电行为，停摆判定必须区分前后台（见 sample）。
        try {
            (app as? Application)?.registerActivityLifecycleCallbacks(lifecycleTracker)
        } catch (_: Throwable) {
        }
        // 上一次进程若是「正常退出」（用户划掉/系统常规回收/升级安装），说明
        // 现有的 crash-freeze.txt 是运行期误报——真卡死/被低内存击杀才会留下
        // 有价值的现场。此时直接清掉，避免用户反复看到一份「没崩溃却有崩溃
        // 记录」的旧文件；上一次是异常退出则保留，供事后分析。
        logFile?.let { file ->
            if (file.exists() && !lastExitAbnormal(app)) file.delete()
        }
        // 头部信息只暂存内存，等真正出现异常时随现场一起落盘。
        headerLines = buildList {
            add("===== XY Music 冻结探针 =====")
            add(
                "进程启动 pid=${Process.myPid()} uptime=${SystemClock.uptimeMillis()}ms " +
                    "设备=${Build.MANUFACTURER} ${Build.MODEL} API=${Build.VERSION.SDK_INT}",
            )
            // 判定口径随现场一起落盘：日后翻日志时不必再回头倒推阈值与
            // 「为什么这条算异常」。Dart 侧每条采样行带 dartLag/probeGap/
            // dartIdle 三项自证数据，据此可直接区分「isolate 真停摆」与
            // 「Dart 主动不探测 / 整机冻结 / 探针自己也被冻结」。
            add(
                "判定口径 采样间隔=${INTERVAL_MS}ms Dart心跳=20s " +
                    "停摆阈值=${DART_LAG_EVENT_MS}ms " +
                    "（需同时满足：前台 + 本探针采样间隔正常）",
            )
            addAll(previousExitInfo(app))
        }
        val thread = HandlerThread("xy-freeze-probe").apply { start() }
        val handler = Handler(thread.looper)
        handler.post(
            object : Runnable {
                override fun run() {
                    try {
                        sample(app)
                    } catch (_: Throwable) {
                        // 探针自身绝不影响主流程。
                    }
                    handler.postDelayed(this, INTERVAL_MS)
                }
            },
        )
    }

    /** Dart 探针每次采样（audioProbe）时调用，用于推算 Dart 主 isolate 是否停摆。 */
    fun noteDartProbe() {
        lastDartProbeAt = SystemClock.uptimeMillis()
        lastDartIdleReason = ""
    }

    /**
     * Dart 侧主动声明「本轮不探测」时调用（后台/暂停/无音源/重建中）。
     *
     * 与 [noteDartProbe] 一样刷新心跳时间戳：这条调用同样是一次 MethodChannel
     * 主线程往返，能到达就说明 Dart 事件循环与原生主线程都还在跑，只是本次
     * 没有探测的必要。否则"暂停播放 60 秒"就会被写成一份崩溃记录。
     */
    fun noteDartProbeIdle(reason: String) {
        lastDartProbeAt = SystemClock.uptimeMillis()
        lastDartIdleReason = reason
    }

    private fun sample(context: Context) {
        val postedAt = SystemClock.uptimeMillis()
        val inGrace = postedAt - startedAtMs < STARTUP_GRACE_MS
        val inForeground = foregroundActivities > 0
        // 主线程调度延迟：从投递到真正执行的时间差。进程被冻结期间投递的
        // 回调会在解冻瞬间立刻执行（lag≈0），不会误报；仅前台卡顿才落盘。
        mainHandler.post {
            val lag = SystemClock.uptimeMillis() - postedAt
            lastMainLagMs = lag
            if (lag >= MAIN_LAG_EVENT_MS && foregroundActivities > 0) {
                record("[${timeFormat.format(Date())}] 主线程卡顿 ${lag}ms pid=${Process.myPid()}", force = true)
            }
        }
        // 探针自证：记录相邻两次采样的真实间隔。进程被系统整体冻结时，这个
        // 采样回调会一起停，间隔必然出现 ≥2 个周期的空档——此时期间累积的
        // dartLag 是「整机冻结」，不能算 Dart 单独停摆（旧口径一边写「系统
        // 冻结，非故障」一边按 20s 阈值判停摆，自己和自己打架）。
        val probeGap = if (lastSampleAt == 0L) 0L else postedAt - lastSampleAt
        lastSampleAt = postedAt
        val proberFrozen = probeGap >= INTERVAL_MS * 2

        val dartLag = if (lastDartProbeAt == 0L) -1L else postedAt - lastDartProbeAt
        val dartIdle = lastDartIdleReason.ifEmpty { "active" }
        val line = memoryLine(context, dartLag, probeGap, dartIdle)
        val dartStalled = dartLag >= DART_LAG_EVENT_MS
        // 停摆判定三档，必须先排除「不该归咎于 Dart」的两种情况：
        // ① 进程在后台：MagicOS/ColorOS 等冻结 Dart isolate 是省电行为
        //    （native 音频线程不受影响，歌照常出声）；
        // ② 探针自身也被冻结（probeGap ≥ 2 个采样周期）：整机冻结，与 Dart 无关。
        // 只有「前台 + 探针自身仍在按周期采样 + Dart 心跳仍不动」才算真故障
        // （ANR 级），才落盘现场——否则正常后台播放/暂停都会留下一份「崩溃
        // 记录」，把真卡死淹没（荣耀 AAP-AN00 实测 37 分钟假停摆即此误报）。
        val dartStallAbnormal = dartStalled && inForeground && !proberFrozen
        if (dartStalled && !dartStallAbnormal && !bgStallNoted) {
            bgStallNoted = true
            val cause = if (proberFrozen) {
                "探针自身也被冻结 ${probeGap}ms，整机冻结，非故障"
            } else {
                "进程在后台，系统冻结 Dart isolate，非故障"
            }
            record("[${timeFormat.format(Date())}] Dart isolate 停摆 ${dartLag}ms（$cause）")
        }
        if (!dartStalled) bgStallNoted = false
        if (dartStallAbnormal) {
            record(
                "[${timeFormat.format(Date())}] Dart 主 isolate 停摆 ${dartLag}ms" +
                    "（probeGap=${probeGap}ms dartIdle=$dartIdle）",
                force = true,
            )
            // 首次判停摆时抓一次全线程状态：直接区分「被锁/IO 阻塞」
            // 与「CPU 空转」。整段一次性写入，避免逐线程开关文件。
            if (!threadDumpDone) {
                threadDumpDone = true
                record(
                    readThreadStates().joinToString(separator = "\n"),
                    force = true,
                )
            }
        }
        // 内存/线程数暴涨同样视为异常：整包缓存或线程栈泄漏会让进程被系统
        // 击杀且不产生崩溃文件，需要留下现场。但启动初始化（线程数瞬时冲到
        // ~160）与 zram 换入换出都会让单次采样虚高，故要求「启动静默期之外 +
        // 连续多次命中」，持续异常才落盘。
        val memHigh = memoryHot(line)
        val threadHigh = intField(line, "threads") >= THREAD_EVENT_COUNT
        memoryStreak = if (!inGrace && memHigh) memoryStreak + 1 else 0
        threadStreak = if (!inGrace && threadHigh) threadStreak + 1 else 0
        val sustained = memoryStreak >= ANOMALY_STREAK || threadStreak >= ANOMALY_STREAK
        val anomaly = dartStallAbnormal || sustained
        record(line, force = anomaly)
        // 区域归属明细要解析整份 smaps（较贵），只在异常路径上按 60s 节流记录：
        // 用来在内存异常时锁定究竟是哪一块映射吃掉了几个 G，以及这块到底是
        // Dart VM 堆还是原生分配（见 readVmaStats）。
        sampleCount++
        if (anomaly && sampleCount % 6L == 0L) {
            val vmas = readVmaStats()
            record("  [regions]${regionSummary(vmas)}", force = true)
            topRegions(vmas, 8).forEach { record(it, force = true) }
            fingerprintRegions(vmas, 2).forEach { record(it, force = true) }
        }
    }

    /**
     * 采样行是否命中内存异常。
     *
     * 只信 smaps_rollup 实测的 pss2：ActivityManager 的 totalPss 在部分
     * MIUI/ColorOS 机型上会被缓存成常量（实测常驻 2~3GB 纹丝不动），单独看它
     * 必然误报。同时要求系统可用内存见底（或系统已报 lowMemory）——只看 PSS 会
     * 被 zram 换入换出造成的瞬时虚高误导（实测 pvDirty 10s 内可在 3GB 与
     * 200MB 之间跳变）。
     */
    private fun memoryHot(line: String): Boolean {
        if (line.contains("low=true")) return true
        val pss2 = mbField(line, "pss2")
        val sysAvail = mbField(line, "sysAvail")
        return pss2 >= MEMORY_EVENT_MB && sysAvail <= MEMORY_SYS_FLOOR_MB
    }

    /** 取采样行里「<key>=1234MB」的数值（pss 与 pss2 前缀不同，分别精确匹配）。 */
    private fun mbField(line: String, key: String): Long =
        Regex("$key=(\\d+)MB").find(line)?.groupValues?.get(1)?.toLongOrNull() ?: 0L

    /** 取采样行里「<key>=1234」的整数值（如 threads=157）。 */
    private fun intField(line: String, key: String): Int =
        Regex("$key=(\\d+)").find(line)?.groupValues?.get(1)?.toIntOrNull() ?: 0

    private fun memoryLine(context: Context, dartLag: Long, probeGap: Long, dartIdle: String): String {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
        var pssKb = 0L
        var detail = ""
        try {
            val memInfo = am?.getProcessMemoryInfo(intArrayOf(Process.myPid()))?.firstOrNull()
            if (memInfo != null) {
                pssKb = memInfo.totalPss.toLong()
                // 分类 PSS：把总量拆到子系统，用来判断泄漏落在哪一类
                // （dalvik=Java 堆、native=native heap/图形/位图像素、
                //  other=代码段/栈/未分类）。公开 API 只有这三项。
                detail = " dalvik=${memInfo.dalvikPss / 1024}MB" +
                    " native=${memInfo.nativePss / 1024}MB" +
                    " other=${memInfo.otherPss / 1024}MB"
            }
        } catch (_: Throwable) {
        }
        val runtime = Runtime.getRuntime()
        val javaUsedMb = (runtime.totalMemory() - runtime.freeMemory()) / 1048576L
        val info = ActivityManager.MemoryInfo()
        am?.getMemoryInfo(info)
        // smaps_rollup / 线程数是判定 "other" 大类泄漏性质的关键：
        // 私有脏页增长 = 匿名 mmap/malloc（原生分配未释放）；
        // 共享/文件页增长 = mmap 的文件（如整包音频缓存）未释放；
        // 线程数持续上涨 = 线程栈泄漏。三者处置方式完全不同。
        val detailRollup = readSmapsRollup()
        val pssMb = pssKb / 1024
        return "[${timeFormat.format(Date())}] mem pss=${pssMb}MB$detail " +
            "javaHeap=${javaUsedMb}MB " +
            "sysAvail=${info.availMem / 1048576L}MB low=${info.lowMemory} " +
            "threads=${readThreadCount()}$detailRollup${readSwapInfo()} " +
            "mainLag=${lastMainLagMs}ms dartLag=${dartLag}ms " +
            // probeGap：相邻两次采样的真实间隔。持续 ≈INTERVAL_MS 说明探针
            // 自己在正常跑；出现 >=2 个周期的空档则说明整个进程被冻结过
            // （此时 dartLag 的增长是整机冻结所致，不能当作 Dart 单独停摆）。
            // dartIdle：Dart 最近一次主动声明的不探测原因（paused/no-source/
            // background/rebuilding/app-alive），空串代表仍在正常发 audioProbe。
            "probeGap=${probeGap}ms dartIdle=${dartIdle.ifEmpty { "active" }}"
    }

    /**
     * 进程换出量与系统 swap 用量。
     *
     * 实测本机 pvDirty 会在 10s 内从 3.4GB 掉到 ~200MB 再涨回，而
     * [ActivityManager.getProcessMemoryInfo] 的 totalPss 却纹丝不动（MIUI
     * 缓存了该值，不可信）。「脏页消失」有两种截然不同的成因：
     *   - 真释放（munmap/madvise）：VmSwap 仍≈0，属于分配后马上归还；
     *   - 被 zram 换出：VmSwap 会同步涨到 GB 级，页并没丢，只是被压缩。
     * 直接读 /proc/self/status 的 VmSwap + /proc/meminfo 的 SwapTotal/Free
     * 即可区分，避免把「换出」误判成「内存被释放」而走错方向。
     */
    private fun readSwapInfo(): String {
        var text = ""
        try {
            File("/proc/self/status").forEachLine { line ->
                when {
                    line.startsWith("VmSize:") -> text += " vmSize=${meminfoMb(line)}MB"
                    line.startsWith("VmRSS:") -> text += " vmRss=${meminfoMb(line)}MB"
                    line.startsWith("VmSwap:") -> text += " vmSwap=${meminfoMb(line)}MB"
                }
            }
        } catch (_: Throwable) {
        }
        try {
            File("/proc/meminfo").forEachLine { line ->
                when {
                    line.startsWith("SwapTotal:") -> text += " swapTotal=${meminfoMb(line)}MB"
                    line.startsWith("SwapFree:") -> text += " swapFree=${meminfoMb(line)}MB"
                }
            }
        } catch (_: Throwable) {
        }
        return text
    }

    /** 取 /proc 里「字段名: 1234 kB」的数值并折算成 MB。 */
    private fun meminfoMb(line: String): Long =
        (line.substringAfter(':').trim().substringBefore(' ').toLongOrNull() ?: 0L) / 1024L

    /** 读取 /proc/self/smaps_rollup，把内存按私有/共享、匿名/文件页拆分（单位 MB）。 */
    private fun readSmapsRollup(): String {
        return try {
            val labels = mapOf(
                "Pss:" to "pss2",
                "Swap:" to "swap",
                "Shared_Clean:" to "shClean",
                "Shared_Dirty:" to "shDirty",
                "Private_Clean:" to "pvClean",
                "Private_Dirty:" to "pvDirty",
                "Anonymous:" to "anon",
                "AnonHugePages:" to "huge",
            )
            val values = LinkedHashMap<String, Long>()
            File("/proc/self/smaps_rollup").forEachLine { line ->
                val label = labels[line.substringBefore(':').trim() + ":"] ?: return@forEachLine
                val kb = line.substringAfter(':').trim().substringBefore(' ').toLongOrNull()
                if (kb != null) values[label] = kb / 1024
            }
            if (values.isEmpty()) "" else " " + values.entries.joinToString(" ") {
                "${it.key}=${it.value}MB"
            }
        } catch (_: Throwable) {
            ""
        }
    }

    /** 当前进程线程数（线程栈泄漏会表现为持续上涨）。 */
    private fun readThreadCount(): Int {
        return try {
            File("/proc/self/status").useLines { lines ->
                lines.firstOrNull { it.startsWith("Threads:") }
                    ?.substringAfter(':')?.trim()?.toIntOrNull() ?: -1
            }
        } catch (_: Throwable) {
            -1
        }
    }

    /**
     * 读取系统记录的“本进程上一次退出原因”，这是判定
     * 「被系统低内存击杀 / 原生崩溃 / ANR / 仍存活」最直接的证据。
     */
    private fun previousExitInfo(context: Context): List<String> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return listOf("上次退出原因：系统 < Android 11，无法读取")
        }
        return try {
            val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val infos = am.getHistoricalProcessExitReasons(context.packageName, 0, 3)
            if (infos.isEmpty()) {
                listOf("上次退出原因：无历史记录（本次为首次启动或记录被清空）")
            } else {
                infos.mapIndexed { index, info ->
                    val time = dateTimeFormat.format(Date(info.timestamp))
                    "上次退出#$index reason=${reasonName(info.reason)} status=${info.status} " +
                        "pss=${info.pss / 1024}MB rss=${info.rss / 1024}MB " +
                        "importance=${info.importance} time=$time desc=${info.description.orEmpty()}"
                }
            }
        } catch (error: Throwable) {
            listOf("上次退出原因：读取失败 ${error.message}")
        }
    }

    /**
     * 上一次进程退出是否属于异常（被低内存击杀 / 原生或 Java 崩溃 / ANR / 信号）。
     * 只有异常退出才说明 crash-freeze.txt 里的现场有分析价值；正常退出
     * （用户划掉、系统常规回收、安装升级）时那份文件只是运行期误报。
     */
    private fun lastExitAbnormal(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false
        return try {
            val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val reason = am.getHistoricalProcessExitReasons(context.packageName, 0, 1)
                .firstOrNull()?.reason
            // 2=SIGNALED 3=LOW_MEMORY 4=CRASH 5=CRASH_NATIVE 6=ANR
            reason == 2 || reason == 3 || reason == 4 || reason == 5 || reason == 6
        } catch (_: Throwable) {
            false
        }
    }

    /**
     * 退出原因码 → 名称。这里用字面量而非 ApplicationExitInfo.REASON_* 常量：
     * 常量所属类仅在 API 30+ 存在，字面量可避免低版本机型的类加载风险。
     */
    private fun reasonName(reason: Int): String = when (reason) {
        0 -> "UNKNOWN"
        1 -> "EXIT_SELF"
        2 -> "SIGNALED"
        3 -> "LOW_MEMORY"
        4 -> "CRASH"
        5 -> "CRASH_NATIVE"
        6 -> "ANR"
        7 -> "INIT_FAILURE"
        8 -> "PERMISSION_CHANGE"
        9 -> "EXCESSIVE_RESOURCE"
        10 -> "USER_REQUESTED"
        11 -> "USER_STOPPED"
        12 -> "DEPENDENCY_DIED"
        13 -> "OTHER"
        14 -> "FREEZER"
        15 -> "PKG_STATE_CHANGE"
        16 -> "PKG_UPDATED"
        else -> "UNKNOWN($reason)"
    }

    /**
     * 一个 VMA 的统计：dirty 直接对应 smaps_rollup 里的 pvDirty。
     * - `size`（end−start）= 虚拟区间大小，用来和 dirty 对比区分
     *   「大块预留 + 部分提交」与「一次性实打实占用」；
     * - `swap` 来自 smaps 的 `Swap:` 字段：**判定「脏页消失」到底是真释放
     *   还是被 zram 换出**的关键——swap≈dirty 的消失量说明页只是被换出；
     * - `huge` 来自 `AnonHugePages:`：大页数量，提示这是不是一整块连续的大分配。
     */
    private class VmaStat(
        val start: Long,
        val end: Long,
        val dirty: Long,
        val swap: Long,
        val huge: Long,
        val perms: String,
        val name: String,
    ) {
        val size: Long get() = end - start
    }

    /** smaps 的 VMA 头行：十六进制地址范围开头。 */
    private val vmaHeaderRegex = Regex("^[0-9a-fA-F]+-[0-9a-fA-F]+\\s")

    /**
     * 解析 /proc/self/smaps，取每个 VMA 的「私有脏页」字节数，用来回答
     * 「那几个 G 到底归谁」——这是 smaps_rollup 给不出的信息。
     *
     * 特意用 Private_Dirty 而不是 maps 的虚拟区间大小：Dart VM 会一次性预留
     * 一大段虚拟地址（可达几个 G）但按需才提交物理页，用虚拟大小会把占用
     * 严重高估；Private_Dirty 才是真正占住物理内存的量，也正是 smaps_rollup
     * 里 pvDirty 的来源，能直接对上。
     */
    private fun readVmaStats(): List<VmaStat> {
        val stats = ArrayList<VmaStat>()
        try {
            var start = 0L
            var end = 0L
            var dirty = 0L
            var swap = 0L
            var huge = 0L
            var perms = ""
            var name = ""
            var hasVma = false
            fun flush() {
                if (hasVma) stats.add(VmaStat(start, end, dirty, swap, huge, perms, name))
            }
            File("/proc/self/smaps").forEachLine { line ->
                if (vmaHeaderRegex.containsMatchIn(line)) {
                    flush()
                    val parts = line.trim().split(Regex("\\s+"), limit = 6)
                    val head = parts[0]
                    val dash = head.indexOf('-')
                    start = head.substring(0, dash).toLongOrNull(16) ?: 0L
                    end = head.substring(dash + 1).toLongOrNull(16) ?: 0L
                    perms = parts.getOrNull(1) ?: ""
                    name = parts.getOrNull(5)?.trim() ?: ""
                    dirty = 0L
                    swap = 0L
                    huge = 0L
                    hasVma = true
                } else if (hasVma) {
                    when {
                        line.startsWith("Private_Dirty:") -> dirty = kbOf(line)
                        // 注意排除 SwapPss:，它同样以 "Swap" 开头。
                        line.startsWith("Swap:") -> swap = kbOf(line)
                        line.startsWith("AnonHugePages:") -> huge = kbOf(line)
                    }
                }
            }
            flush()
        } catch (_: Throwable) {
        }
        return stats
    }

    /** 取 smaps 行「字段名: 1234 kB」里的数值，折算成字节。 */
    private fun kbOf(line: String): Long =
        (line.substringAfter(':').trim().substringBefore(' ').toLongOrNull() ?: 0L) * 1024L

    /**
     * 按区域名聚合私有脏页（MB）：
     *
     * - 无路径匿名区（`anonNoName`）= Dart VM 堆或进程自己 mmap 的缓冲区。
     *   内核会把属性相同的相邻匿名 VMA 合并，Dart 堆可能只体现为一两块，因此
     *   `n` 不能当判据，要靠 `malloc=` 与具名区交叉印证。
     * - 具名区：`[anon:scudo:*]`/`[anon:libc_malloc]` = 原生 malloc（同时反映在
     *   `malloc=` 一栏的 [Debug.getNativeHeapAllocatedSize]）；`[anon:thread stack]`
     *   = 线程栈；`.so`/`.dex`/字体 = 代码与资源。
     * 若 `anonNoName` 吃掉几 G、而 `malloc=` 与具名区都远小于它，即可判定这部分
     * 是 Dart VM 堆（或裸 mmap），而非原生分配。
     */
    private fun regionSummary(stats: List<VmaStat>): String {
        if (stats.isEmpty()) return ""
        var noName = 0L
        var noNameCount = 0
        var noNameMax = 0L
        val named = HashMap<String, Long>()
        for (s in stats) {
            if (s.name.isEmpty()) {
                noName += s.dirty
                noNameCount++
                if (s.dirty > noNameMax) noNameMax = s.dirty
            } else {
                val key = mapKey(s.name)
                named[key] = (named[key] ?: 0L) + s.dirty
            }
        }
        val top = named.entries.sortedByDescending { it.value }.take(5)
            .joinToString(",") { "${it.key}=${it.value / 1048576}MB" }
        return " anonNoName=${noName / 1048576}MB(n=$noNameCount,max=${noNameMax / 1048576}MB)" +
            " malloc=${Debug.getNativeHeapAllocatedSize() / 1048576L}MB top[$top]"
    }

    /** 私有脏页最大的若干区域，内存异常时定位具体归属（含起始地址/大小/换出）。 */
    private fun topRegions(stats: List<VmaStat>, limit: Int): List<String> {
        return stats.filter { it.dirty > 0 }
            .sortedByDescending { it.dirty }
            .take(limit)
            .map {
                // 起始地址用于跨采样追踪同一块区域；size/swap/huge 帮助
                // 区分「Dart 堆（大预留+部分提交+有换出）」与「一次性大缓冲」。
                val startHex = java.lang.Long.toHexString(it.start)
                val extras = buildList {
                    add("size=${it.size / 1048576}MB")
                    if (it.swap > 0) add("swap=${it.swap / 1048576}MB")
                    if (it.huge >= 2L * 1048576) add("huge=${it.huge / 1048576}MB")
                }
                "  ${it.dirty / 1048576}MB ${it.perms} @0x$startHex (${extras.joinToString(" ")})" +
                    " ${displayName(it.name)}"
            }
    }

    private fun displayName(path: String): String = when {
        path.isEmpty() -> "匿名-无路径"
        path.startsWith("/") -> path.substringAfterLast('/')
        else -> path
    }

    /**
     * 对最大的若干「无路径匿名区」做内容指纹：在区域内多点各读 4KB，统计全零
     * 字节占比与可打印 ASCII 占比，并给出可打印内容预览。用来把「无名大块」
     * 再区分为：
     *   - Dart VM 堆：含对象头/指针（零字节偏多）与大量字符串（可打印占比明显
     *     偏高，预览里甚至能直接看到歌词/URL 文案）；
     *   - 音频 PCM / 压缩数据缓冲：可打印占比极低；
     *   - 未提交的预留页：几乎全零（读不到也算一类证据）。
     */
    private fun fingerprintRegions(stats: List<VmaStat>, limit: Int): List<String> {
        val targets = stats
            .filter { it.name.isEmpty() && it.perms.startsWith("r") && it.dirty >= 64L * 1048576 }
            .sortedByDescending { it.dirty }
            .take(limit)
        if (targets.isEmpty()) return emptyList()
        val file = try {
            RandomAccessFile("/proc/self/mem", "r")
        } catch (error: Throwable) {
            // 之前这里静默 return，导致 [fp] 一条都不出却无从判断原因；
            // 把异常写进日志：EACCES（SELinux 禁读）与 ESRCH/EPERM 处置不同。
            return listOf(
                "  [fp] 打开 /proc/self/mem 失败：${error.javaClass.simpleName} ${error.message}",
            )
        }
        val out = ArrayList<String>()
        var readError: String? = null
        try {
            for (t in targets) {
                var zeros = 0L
                var printable = 0L
                var total = 0L
                val preview = StringBuilder()
                val span = t.end - t.start
                for (i in 0 until 8) {
                    if (span <= 0L) break
                    val offset = t.start + span / 8 * i
                    val buf = ByteArray(4096)
                    val read = try {
                        file.seek(offset)
                        file.read(buf)
                    } catch (error: Throwable) {
                        readError = "${error.javaClass.simpleName} ${error.message}"
                        -1
                    }
                    if (read <= 0) continue
                    for (j in 0 until read) {
                        val b = buf[j].toInt() and 0xFF
                        if (b == 0) zeros++
                        if (b in 0x20..0x7E) {
                            printable++
                            if (preview.length < 64) preview.append(b.toChar())
                        }
                    }
                    total += read
                }
                if (total <= 0L) {
                    val why = readError?.let { "（读取失败：$it）" } ?: "（多为未提交预留页）"
                    out.add("  [fp] ${t.dirty / 1048576}MB 无可读采样$why")
                    continue
                }
                out.add(
                    "  [fp] ${t.dirty / 1048576}MB zero=${zeros * 100 / total}%" +
                        " printable=${printable * 100 / total}% preview=\"$preview\"",
                )
            }
        } finally {
            try {
                file.close()
            } catch (_: Throwable) {
            }
        }
        return out
    }

    /** 把 maps 路径归一成可聚合的短名（保留 [anon:...] 标签，文件取 basename）。 */
    private fun mapKey(path: String): String {
        if (path.startsWith("[")) return path
        val slash = path.lastIndexOf('/')
        return if (slash < 0) path else path.substring(slash + 1)
    }

    /**
     * 卡死瞬间的全线程状态快照：扫描 /proc/self/task 下各线程，读取每个线程的
     * comm（线程名）、stat（状态字符）与 wchan（内核等待点）。用来回答
     * 「Dart UI 线程到底是卡在锁/IO 上，还是在 CPU 上空转」：
     *   - state=R 且 wchan 为空 → 正在空转（典型的死循环/忙等）；
     *   - state=S/D 且 wchan 含 futex/mutex → 阻塞在锁上（可能是原生互斥量死锁）；
     *   - wchan 含 poll/read/epoll_wait → 阻塞在 IO。
     * wchan 在部分内核/受限机型上可能读不到（为空或 "0"），此时以 state 为准。
     */
    private fun readThreadStates(): List<String> {
        return try {
            val tids = File("/proc/self/task").list()?.filter { it.toIntOrNull() != null }
                ?: return emptyList()
            val out = ArrayList<String>()
            out.add("  [threads]")
            for (tid in tids) {
                val base = "/proc/self/task/$tid"
                val comm = try {
                    File("$base/comm").readText().trim()
                } catch (_: Throwable) {
                    ""
                }
                val stat = try {
                    File("$base/stat").readText()
                } catch (_: Throwable) {
                    ""
                }
                // stat 形如 "1234 (name) R 567 ..."：右括号后第一个字段就是状态字符。
                val close = stat.lastIndexOf(')')
                val state = if (close in 0 until stat.length - 2) stat[close + 2].toString() else "?"
                val wchan = try {
                    File("$base/wchan").readText().trim()
                } catch (_: Throwable) {
                    ""
                }
                out.add(
                    "    ${comm.ifEmpty { "?" }}" +
                        " tid=$tid state=$state" +
                        " tid=$tid state=$state" +
                        " wchan=${wchan.ifEmpty { "-" }}",
                )
            }
            out
        } catch (_: Throwable) {
            emptyList()
        }
    }

    /**
     * 记录一行采样。[force] 为 true（命中异常）时先把内存环形缓冲里的历史
     * 现场落盘，再追加当前行；否则只进环形缓冲、不落盘。
     */
    private fun record(line: String, force: Boolean = false) {
        synchronized(lock) {
            ring.addLast(line)
            while (ring.size > RING_SIZE) ring.removeFirst()
            if (!force) return
            val file = logFile ?: return
            try {
                if (!flushed) {
                    file.parentFile?.mkdirs()
                    file.appendText(headerLines.joinToString(separator = "\n", postfix = "\n"))
                    // 环形缓冲里混着自我说明性质的「非故障」行（后台停摆、
                    // 整机冻结等）。它们只该留在内存里解释上下文，不该进崩溃
                    // 文件——否则导出的「崩溃记录」里出现「非故障」字样与真
                    // 现场并列，既误导判断，也让这份文件的意义失效。
                    file.appendText(
                        ring.filterNot { it.contains("非故障") }
                            .joinToString(separator = "\n", postfix = "\n"),
                    )
                    flushed = true
                } else {
                    file.appendText(line + "\n")
                }
                appendCount++
                if (appendCount % TRIM_EVERY == 0) trim(file)
            } catch (_: Throwable) {
            }
        }
    }

    private fun trim(file: File) {
        val lines = file.readLines()
        if (lines.size <= MAX_LINES) return
        file.writeText(lines.takeLast(MAX_LINES).joinToString(separator = "\n", postfix = "\n"))
    }
}
