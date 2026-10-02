package com.ryanheise.audioservice;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * XY Music 定制：媒体通知的 contentIntent 在关闭
 * {@code androidNotificationClickStartsActivity} 时会指向本广播接收器。
 *
 * 这样单击通知（含快捷设置里的媒体卡片）不会拉起 Activity、不会把应用切到
 * 前台，只把单击事件转交 Dart 的 AudioHandler（onNotificationClicked），
 * 由 Dart 侧打开迷你播放器悬浮窗。
 */
public class NotificationClickReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        if (intent != null && AudioService.NOTIFICATION_CLICK_ACTION.equals(intent.getAction())) {
            AudioService.handleNotificationClick();
        }
    }
}