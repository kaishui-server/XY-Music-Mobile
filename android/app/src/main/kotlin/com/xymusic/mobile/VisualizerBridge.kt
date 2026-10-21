package com.xymusic.mobile

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.media.audiofx.Visualizer
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * 可视化频谱桥：基于系统 android.media.audiofx.Visualizer 采集输出混音的
 * FFT 数据，经 EventChannel 以约 20Hz 推给 Dart 侧（Dart 端按帧插值到
 * 60fps 渲染）。挂在输出混音（session 0）上，主播放链路（ExoPlayer）与
 * 本地回环代理等场景都能取到频谱。
 *
 * 需要 RECORD_AUDIO 运行时权限（Manifest 已声明，此处负责检查/发起申请，
 * Dart 侧轮询授权结果）。
 */
object VisualizerBridge {
    private const val METHOD_CHANNEL = "com.xymusic.mobile/visualizer"
    private const val EVENT_CHANNEL = "com.xymusic.mobile/visualizer_events"
    private const val REQUEST_RECORD_AUDIO = 0x565A

    private val mainHandler = Handler(Looper.getMainLooper())
    private var visualizer: Visualizer? = null
    private var eventSink: EventChannel.EventSink? = null
    private var activity: Activity? = null

    fun register(messenger: BinaryMessenger, hostActivity: Activity) {
        activity = hostActivity
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "hasPermission" -> result.success(hasRecordAudioPermission())
                "requestPermission" -> {
                    val host = activity
                    if (host == null) {
                        result.success(false)
                    } else if (hasRecordAudioPermission()) {
                        result.success(true)
                    } else {
                        androidx.core.app.ActivityCompat.requestPermissions(
                            host,
                            arrayOf(Manifest.permission.RECORD_AUDIO),
                            REQUEST_RECORD_AUDIO,
                        )
                        // 申请是异步的：Dart 侧轮询 hasPermission 拿最终结果。
                        result.success(true)
                    }
                }
                "start" -> {
                    try {
                        startListening()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("visualizer_start_failed", e.message, null)
                    }
                }
                "stop" -> {
                    stopListening()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    eventSink = sink
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            },
        )
    }

    private fun hasRecordAudioPermission(): Boolean {
        val host = activity ?: return false
        return ContextCompat.checkSelfPermission(host, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
    }

    @Synchronized
    private fun startListening() {
        if (visualizer != null) return
        // session 0 = 全局输出混音。
        val v = Visualizer(0)
        v.captureSize = Visualizer.getCaptureSizeRange()[1]
        v.setDataCaptureListener(
            object : Visualizer.OnDataCaptureListener {
                override fun onWaveFormDataCapture(
                    visualizer: Visualizer?,
                    waveform: ByteArray?,
                    samplingRate: Int,
                ) {
                    val sink = eventSink ?: return
                    val data = waveform ?: return
                    val copy = data.copyOf()
                    mainHandler.post { sink.success(arrayListOf<Any>("w", copy, samplingRate)) }
                }

                override fun onFftDataCapture(
                    visualizer: Visualizer?,
                    fft: ByteArray?,
                    samplingRate: Int,
                ) {
                    val sink = eventSink ?: return
                    val data = fft ?: return
                    val copy = data.copyOf()
                    mainHandler.post { sink.success(arrayListOf<Any>("f", copy)) }
                }
            },
            Visualizer.getMaxCaptureRate(),
            true,
            true,
        )
        v.enabled = true
        visualizer = v
    }

    @Synchronized
    private fun stopListening() {
        visualizer?.let { v ->
            try {
                v.enabled = false
                v.setDataCaptureListener(null, 0, false, false)
                v.release()
            } catch (_: Exception) {
            }
        }
        visualizer = null
    }
}
