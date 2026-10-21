package com.ryanheise.audioservice;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Handler;
import android.os.Looper;

import com.ryanheise.audioservice.AudioService;

/**
 * XY Music 定制：媒体通知 contentIntent 的进程内广播接收器。
 *
 * 交互逻辑（单/双击 debounce）：
 * - 单击（600ms 内无第二次点击）：进入软件（拉起 MainActivity）；
 * - 双击（600ms 内第二次点击）：进入软件并自动开启桌面歌词悬浮窗。
 *
 * 实现要点：第一击先不动作，延迟 600ms 判定；期间第二击到达则取消
 * 单击动作、执行双击动作（QQ音乐同款手感）。
 */
public class NotificationClickReceiver extends BroadcastReceiver {

    /**
     * 双击判定窗口（毫秒）。通知点击后面板收起动画会吞掉第二击落点，
     * 600ms 对通知双击偏紧（实测多落在 300~800ms），放宽到 750ms 提高
     * 命中率；代价是单击进软件延迟到 750ms（体感可接受）。
     */
    private static final long DOUBLE_CLICK_WINDOW = 750L;

    private static final Handler handler = new Handler(Looper.getMainLooper());

    private static Runnable pendingSingleClick = null;

    @Override
    public void onReceive(final Context context, Intent intent) {
        final Intent launch = new Intent();
        launch.setClassName(context, context.getPackageName() + ".MainActivity");
        launch.setAction(Intent.ACTION_MAIN);
        launch.addCategory(Intent.CATEGORY_LAUNCHER);
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK |
                Intent.FLAG_ACTIVITY_SINGLE_TOP);
        if (pendingSingleClick != null) {
            // 600ms 内第二击：双击 → 进软件并自动开桌面歌词悬浮窗。
            handler.removeCallbacks(pendingSingleClick);
            pendingSingleClick = null;
            launch.putExtra("auto_enable_desktop_lyrics", true);
            context.startActivity(launch);
            return;
        }
        // 第一击：延迟判定，无第二击则执行「单击 = 进软件」。
        pendingSingleClick = new Runnable() {
            @Override
            public void run() {
                pendingSingleClick = null;
                context.startActivity(launch);
            }
        };
        handler.postDelayed(pendingSingleClick, DOUBLE_CLICK_WINDOW);
    }
}
