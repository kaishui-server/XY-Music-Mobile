package com.ryanheise.audioservice;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * XY Music 定制：媒体通知 contentIntent 的进程内广播接收器。
 *
 * 点击（含荣耀灵动胶囊单击）= 进入软件（拉起 MainActivity），无任何
 * 悬浮窗相关动作。历史上的「双击自动开桌面歌词」已移除：MagicOS 的
 * 胶囊单击常被系统拆成两次广播，会误入双击分支，在无悬浮窗权限时把
 * 用户拉到「显示在其他应用上层」授权页（弹页只允许发生在设置页手动
 * 开启小窗类功能时，见 MainActivity.setEnabled 的权限规范）。
 */
public class NotificationClickReceiver extends BroadcastReceiver {

    @Override
    public void onReceive(Context context, Intent intent) {
        final Intent launch = new Intent();
        launch.setClassName(context, context.getPackageName() + ".MainActivity");
        launch.setAction(Intent.ACTION_MAIN);
        launch.addCategory(Intent.CATEGORY_LAUNCHER);
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK |
                Intent.FLAG_ACTIVITY_SINGLE_TOP);
        context.startActivity(launch);
    }
}
