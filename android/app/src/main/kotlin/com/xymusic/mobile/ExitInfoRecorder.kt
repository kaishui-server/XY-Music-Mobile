package com.xymusic.mobile

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import java.io.File

/**
 * 原生闪退补录（ApplicationExitInfo）。
 *
 * 背景：硬性原生崩溃（SIGSEGV/SIGABRT，多发生在 Flutter 引擎/ExoPlayer/
 * Rust 层）不会走 Java 的 UncaughtExceptionHandler，CrashHandler.kt 与
 * Dart 侧 AppLogStore 都来不及写；且用户反馈「打开就闪退，几秒钟就死」，
 * Dart 日志初始化之前进程就没了——两台设备（vivo/小米）闪退均零留痕。
 *
 * 方案：App 启动极早期（MainActivity.onCreate，先于 Flutter 引擎）读取
 * 系统保留的上一次进程退出记录（API 30+，两台问题设备均为 Android 14）。
 * 若退出原因为 崩溃/信号/ANR/低内存/原生崩溃/资源滥用，立即写入
 * CrashHandler.crashDir 同目录的 crash-exit-<时间>.txt。下次启动能进 App
 * 时，用户在 设置→日志→崩溃记录 即可导出上次闪退的原因（含 signal 描述）。
 *
 * 只记录一次：以退出时间戳为去重标记存于 filesDir 防止重复写。
 */
object ExitInfoRecorder {
    /** 只关心这些异常退出原因；EXIT_SELF(1)/USER_REQUESTED(9) 等正常退出忽略。 */
    private val INTERESTING_REASONS = setOf(
        2, // REASON_SIGNALED：被信号杀死（SIGSEGV/SIGABRT 等最常见）
        3, // REASON_LOW_MEMORY
        4, // REASON_ANR
        5, // REASON_CRASH
        6, // REASON_CRASH_INIT
        7, // REASON_CRASH_NATIVE
        8, // REASON_EXCESSIVE_RESOURCE_USAGE
    )

    private const val MARKER_FILE = "xy_music_exit_info_marker"

    fun recordLastExitIfCrash(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        try {
            val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val records: List<ApplicationExitInfo> =
                am.getHistoricalProcessExitReasons(context.packageName, 0, 3)
            val record = records.firstOrNull() ?: return
            val reason = record.reason
            if (reason !in INTERESTING_REASONS) return

            val exitTime = record.timestamp
            val marker = File(context.filesDir, MARKER_FILE)
            if (marker.exists() && marker.readText().trim() == exitTime.toString()) {
                return // 这条已经落过盘，不重复写
            }

            val dir = CrashHandler.crashDir(context)
            val time = java.text.SimpleDateFormat(
                "yyyyMMdd-HHmmss", java.util.Locale.US,
            ).format(java.util.Date())
            val file = File(dir, "crash-exit-$time.txt")
            val versionInfo = try {
                context.packageManager.getPackageInfo(context.packageName, 0)
            } catch (_: Exception) {
                null
            }
            val content = buildString {
                appendLine("===== XY Music 原生闪退补录（ApplicationExitInfo） =====")
                appendLine("上次退出时间: ${java.util.Date(exitTime)}")
                appendLine("退出原因码: $reason (${reasonName(reason)})")
                appendLine("描述: ${record.description ?: "(无)"}")
                appendLine("状态: ${record.status}")
                appendLine("设备: ${Build.MANUFACTURER} ${Build.MODEL} (Android ${Build.VERSION.RELEASE}, API ${Build.VERSION.SDK_INT})")
                appendLine("版本: ${versionInfo?.versionName ?: ""} (构建 ${versionInfo?.longVersionCode ?: 0L})")
                appendLine("============================")
                appendLine("说明: 以上信息由系统 ApplicationExitInfo 提供，崩溃发生时")
                appendLine("进程直接死亡（Dart/Java 崩溃处理器均未及写入）。`描述` 字段")
                appendLine("通常包含 signal 编号与 fault addr，可定位崩溃层（引擎/播放器/Rust）。")
            }
            file.writeText(content)
            marker.writeText(exitTime.toString())
            // 镜像到公共下载目录（Download/XY Music/）：用户文件管理器直接
            // 可见——「打开就闪退」拿不到应用私有目录，下载目录里的这份
            // 上次闪退日志就是第一手现场。
            val publicPath = DownloadsExporter.saveText(context, file.name, content)
            CrashHandler.trimOldFilesCompat(dir)
            if (publicPath == null) {
                // 镜像失败（极少数 ROM 限制 MediaStore）：在崩溃目录内留下
                // 一个空标记，Dart 侧提示仍引导用户走 设置→日志→崩溃记录。
                try {
                    File(dir, "crash-exit-mirror-failed").writeText("")
                } catch (_: Throwable) {}
            }
        } catch (_: Throwable) {
            // 补录自身失败绝不能影响启动。
        }
    }

    private fun reasonName(reason: Int): String = when (reason) {
        2 -> "SIGNALED(被信号杀死,原生崩溃最常见)"
        3 -> "LOW_MEMORY(低内存被杀)"
        4 -> "ANR(应用无响应)"
        5 -> "CRASH(Java/Dart崩溃)"
        6 -> "CRASH_INIT(初始化崩溃)"
        7 -> "CRASH_NATIVE(原生崩溃)"
        8 -> "EXCESSIVE_RESOURCE_USAGE(资源滥用)"
        else -> "UNKNOWN"
    }
}
