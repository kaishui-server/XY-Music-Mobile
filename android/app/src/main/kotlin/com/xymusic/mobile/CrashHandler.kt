package com.xymusic.mobile

import android.content.Context
import android.os.Build
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 参考 legado（开源阅读）的 CrashHandler 设计：
 * 进程内任何线程出现未捕获异常（OOM、Kotlin/Java 崩溃、Flutter 引擎
 * 原生崩溃）时，先把崩溃堆栈与设备信息同步写入应用私有目录的
 * crash/crash-<时间>.txt 文件，再交回系统默认处理（进程退出、弹"停止运行"）。
 *
 * 写入 filesDir（应用内部存储），不申请任何存储权限。
 */
object CrashHandler {
    /** 最多保留的崩溃文件数，超出时删除最旧的。 */
    private const val MAX_FILES = 20

    @Volatile
    private var installed = false

    /** 崩溃文件目录：<filesDir>/xy_music/crash，与 Dart 侧通过通道共享该路径。 */
    fun crashDir(context: Context): File =
        File(File(context.filesDir, "xy_music"), "crash").apply { mkdirs() }

    fun install(context: Context) {
        if (installed) return
        installed = true
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                writeCrashFile(context, thread, throwable)
            } catch (_: Throwable) {
                // 崩溃记录自身失败时绝不能阻塞原始崩溃流程。
            }
            // 交回系统默认处理，保持"应用已停止运行"的原生行为。
            previous?.uncaughtException(thread, throwable)
        }
    }

    private fun writeCrashFile(context: Context, thread: Thread, throwable: Throwable) {
        val dir = crashDir(context)
        val time = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())
        val file = File(dir, "crash-$time.txt")
        val stack = StringWriter().also { throwable.printStackTrace(PrintWriter(it)) }.toString()
        val versionName = try {
            context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: ""
        } catch (_: Exception) {
            ""
        }
        file.writeText(
            buildString {
                appendLine("===== XY Music 原生崩溃 =====")
                appendLine("时间: $time")
                appendLine("线程: ${thread.name}")
                appendLine("设备: ${Build.MANUFACTURER} ${Build.MODEL} (Android ${Build.VERSION.RELEASE}, API ${Build.VERSION.SDK_INT})")
                appendLine("版本: $versionName")
                appendLine("============================")
                appendLine(stack)
            },
        )
        trimOldFiles(dir)
    }

    private fun trimOldFiles(dir: File) {
        val files = dir.listFiles() ?: return
        files.sortedByDescending { it.name }.drop(MAX_FILES).forEach { it.delete() }
    }
}
