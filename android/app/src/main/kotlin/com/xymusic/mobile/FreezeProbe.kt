package com.xymusic.mobile

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import java.io.File
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
 * 命中异常（主线程长时间卡顿 / Dart isolate 停摆 / 内存或线程数暴涨）才把
 * 最近一段现场一次性写入 <filesDir>/xy_music/crash/crash-freeze.txt。这样
 * 「软件没崩溃却总有一份崩溃记录」的误报消失，而真卡死时仍能拿到卡死前
 * 的现场。文件名以 crash- 开头，会被「日志-崩溃记录」导出自动收录。
 */
object FreezeProbe {
    /** 采样间隔。 */
    private const val INTERVAL_MS = 10_000L

    /** 主线程延迟超过该值记一条事件。 */
    private const val MAIN_LAG_EVENT_MS = 8_000L

    /** Dart 探针超过该值未刷新即判定 Dart 主 isolate 停摆。 */
    private const val DART_LAG_EVENT_MS = 20_000L

    /** 进程 PSS 超过该值即判定内存异常（正常播放约 150~400MB）。 */
    private const val MEMORY_EVENT_MB = 1024L

    /** 线程数超过该值即判定线程泄漏（正常约 80）。 */
    private const val THREAD_EVENT_COUNT = 150

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

    /** 最近一次测得的主线程延迟（ms）。 */
    @Volatile
    private var lastMainLagMs = 0L

    private val mainHandler = Handler(Looper.getMainLooper())
    private val lock = Any()
    private var logFile: File? = null
    private var appendCount = 0

    /** 正常采样行的内存环形缓冲：命中异常时整段刷盘还原卡死过程。 */
    private val ring = ArrayDeque<String>()
    private var headerLines: List<String> = emptyList()
    private var flushed = false

    fun start(context: Context) {
        if (started) return
        started = true
        val app = context.applicationContext
        logFile = File(CrashHandler.crashDir(app), FILE_NAME)
        // 头部信息只暂存内存，等真正出现异常时随现场一起落盘。
        headerLines = buildList {
            add("===== XY Music 冻结探针 =====")
            add(
                "进程启动 pid=${Process.myPid()} uptime=${SystemClock.uptimeMillis()}ms " +
                    "设备=${Build.MANUFACTURER} ${Build.MODEL} API=${Build.VERSION.SDK_INT}",
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
    }

    private fun sample(context: Context) {
        val postedAt = SystemClock.uptimeMillis()
        // 主线程调度延迟：从投递到真正执行的时间差。
        mainHandler.post {
            val lag = SystemClock.uptimeMillis() - postedAt
            lastMainLagMs = lag
            if (lag >= MAIN_LAG_EVENT_MS) {
                record("[${timeFormat.format(Date())}] 主线程卡顿 ${lag}ms pid=${Process.myPid()}", force = true)
            }
        }
        val dartLag = if (lastDartProbeAt == 0L) -1L else postedAt - lastDartProbeAt
        val line = memoryLine(context, dartLag)
        val dartStalled = dartLag >= DART_LAG_EVENT_MS
        if (dartStalled) {
            record("[${timeFormat.format(Date())}] Dart 主 isolate 停摆 ${dartLag}ms", force = true)
        }
        // 内存/线程数暴涨同样视为异常：整包缓存或线程栈泄漏会让进程被系统
        // 击杀且不产生崩溃文件，需要留下现场。
        record(line, force = dartStalled || memoryAnomaly(line))
    }

    /** 采样行是否命中内存异常（PSS 过高 / 线程数过多）。 */
    private fun memoryAnomaly(line: String): Boolean {
        val pss = Regex("pss=(\\d+)MB").find(line)?.groupValues?.get(1)?.toLongOrNull() ?: 0L
        val threads = Regex("threads=(\\d+)").find(line)?.groupValues?.get(1)?.toIntOrNull() ?: 0
        return pss >= MEMORY_EVENT_MB || threads >= THREAD_EVENT_COUNT
    }

    private fun memoryLine(context: Context, dartLag: Long): String {
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
        return "[${timeFormat.format(Date())}] mem pss=${pssKb / 1024}MB$detail " +
            "javaHeap=${javaUsedMb}MB " +
            "sysAvail=${info.availMem / 1048576L}MB low=${info.lowMemory} " +
            "threads=${readThreadCount()}$detailRollup " +
            "mainLag=${lastMainLagMs}ms dartLag=${dartLag}ms"
    }

    /** 读取 /proc/self/smaps_rollup，把内存按私有/共享、匿名/文件页拆分（单位 MB）。 */
    private fun readSmapsRollup(): String {
        return try {
            val labels = mapOf(
                "Pss:" to "pss2",
                "Shared_Clean:" to "shClean",
                "Shared_Dirty:" to "shDirty",
                "Private_Clean:" to "pvClean",
                "Private_Dirty:" to "pvDirty",
                "Anonymous:" to "anon",
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
                    file.appendText(ring.joinToString(separator = "\n", postfix = "\n"))
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
