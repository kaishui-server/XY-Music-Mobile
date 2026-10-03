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
 * 日志写入 <filesDir>/xy_music/crash/crash-freeze.txt；文件名以 crash- 开头，
 * 会被「日志-崩溃记录」导出自动收录。
 */
object FreezeProbe {
    /** 采样间隔。 */
    private const val INTERVAL_MS = 10_000L

    /** 主线程延迟超过该值记一条事件。 */
    private const val MAIN_LAG_EVENT_MS = 8_000L

    /** Dart 探针超过该值未刷新即判定 Dart 主 isolate 停摆。 */
    private const val DART_LAG_EVENT_MS = 20_000L

    /** 冻结日志最多保留的行数（约 50 分钟历史）。 */
    private const val MAX_LINES = 320

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

    fun start(context: Context) {
        if (started) return
        started = true
        val app = context.applicationContext
        logFile = File(CrashHandler.crashDir(app), FILE_NAME)
        append("===== XY Music 冻结探针 =====")
        append(
            "进程启动 pid=${Process.myPid()} uptime=${SystemClock.uptimeMillis()}ms " +
                "设备=${Build.MANUFACTURER} ${Build.MODEL} API=${Build.VERSION.SDK_INT}",
        )
        appendPreviousExitInfo(app)
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
                append("[${timeFormat.format(Date())}] 主线程卡顿 ${lag}ms pid=${Process.myPid()}")
            }
        }
        val dartLag = if (lastDartProbeAt == 0L) -1L else postedAt - lastDartProbeAt
        if (dartLag >= DART_LAG_EVENT_MS) {
            append("[${timeFormat.format(Date())}] Dart 主 isolate 停摆 ${dartLag}ms")
        }
        append(memoryLine(context, dartLag))
    }

    private fun memoryLine(context: Context, dartLag: Long): String {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
        var pssKb = 0L
        try {
            pssKb = am?.getProcessMemoryInfo(intArrayOf(Process.myPid()))
                ?.firstOrNull()?.totalPss?.toLong() ?: 0L
        } catch (_: Throwable) {
        }
        val runtime = Runtime.getRuntime()
        val javaUsedMb = (runtime.totalMemory() - runtime.freeMemory()) / 1048576L
        val info = ActivityManager.MemoryInfo()
        am?.getMemoryInfo(info)
        return "[${timeFormat.format(Date())}] mem pss=${pssKb / 1024}MB " +
            "javaHeap=${javaUsedMb}MB " +
            "sysAvail=${info.availMem / 1048576L}MB low=${info.lowMemory} " +
            "mainLag=${lastMainLagMs}ms dartLag=${dartLag}ms"
    }

    /**
     * 读取系统记录的“本进程上一次退出原因”，这是判定
     * 「被系统低内存击杀 / 原生崩溃 / ANR / 仍存活」最直接的证据。
     */
    private fun appendPreviousExitInfo(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            append("上次退出原因：系统 < Android 11，无法读取")
            return
        }
        try {
            val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val infos = am.getHistoricalProcessExitReasons(context.packageName, 0, 3)
            if (infos.isEmpty()) {
                append("上次退出原因：无历史记录（本次为首次启动或记录被清空）")
                return
            }
            infos.forEachIndexed { index, info ->
                val time = dateTimeFormat.format(Date(info.timestamp))
                append(
                    "上次退出#$index reason=${reasonName(info.reason)} status=${info.status} " +
                        "pss=${info.pss / 1024}MB rss=${info.rss / 1024}MB " +
                        "importance=${info.importance} time=$time desc=${info.description.orEmpty()}",
                )
            }
        } catch (error: Throwable) {
            append("上次退出原因：读取失败 ${error.message}")
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

    private fun append(line: String) {
        val file = logFile ?: return
        synchronized(lock) {
            try {
                file.appendText(line + "\n")
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