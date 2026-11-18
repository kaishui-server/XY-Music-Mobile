import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../../src/core/settings.dart';
import '../../src/library/library_provider.dart';
import '../../src/player/android_storage.dart';
import '../../src/core/platform_capabilities.dart';
import '../../src/core/db_path.dart';
import '../../src/core/custom_font.dart';
import '../../src/auth/auth_provider.dart';
import '../../src/backup/backup_service.dart';
import '../../src/favorites/favorites_provider.dart';
import '../../src/navigation/settings_expand_transition.dart';
import '../../src/navigation/sidebar_controller.dart';
import '../../src/player/bluetooth_lyrics_switch.dart';
import '../../src/player/desktop_lyrics.dart';
import '../../src/player/mini_player_overlay.dart';
import '../../src/playlists/playlists_provider.dart';
import '../../src/plugins/plugin_runtime.dart';
import '../../src/recent/recent_provider.dart';
import '../../src/ui/xy_surface.dart';
import '../../src/widgets/color_picker_body.dart';
import '../../src/widgets/color_picker_sheet.dart';
import '../../src/widgets/frosted_search_field.dart';
import '../../src/widgets/lyric_settings_sheet.dart';
import '../../src/widgets/top_notice.dart';

enum SettingsSection {
  root,
  account,
  appearance,
  layout,
  sidebarLayout,
  bottomBar,
  playback,
  /// 音量调节设置：从「音乐 › 播放」进入的三级页面。
  volume,
  playbackDetail,
  lyrics,
  desktopLyrics,
  download,
  backup,
  other,
  feedback,
}

class SettingsSearchEntry {
  const SettingsSearchEntry({
    required this.title,
    required this.path,
    required this.route,
    required this.icon,
    this.keywords = '',
    this.note,
  });

  final String title;
  final List<String> path;
  final String route;
  final IconData icon;
  final String keywords;

  /// 可选入口标注：条目所在功能不在设置页层级内时（如音乐库页、侧边栏），
  /// 在搜索结果的路径后缀上补充说明，避免用户按路径找不到入口。
  final String? note;

  int get level => path.length;
}

const settingsSearchEntries = <SettingsSearchEntry>[
  SettingsSearchEntry(
    title: '账号',
    path: ['账号', '账号与安全'],
    route: '/account?from=settings',
    icon: Icons.manage_accounts_outlined,
    keywords: '登录 注册 账号与安全 账号安全 退出',
  ),
  SettingsSearchEntry(
    title: '网盘账号绑定',
    path: ['账号', '网盘账号绑定'],
    route: '/cloud-bind',
    icon: Icons.cloud_outlined,
    keywords: '百度网盘 阿里云盘 夸克 UC 天翼 移动 迅雷 123 PikPak 绑定 登录',
  ),
  SettingsSearchEntry(
    title: '外观',
    path: ['外观'],
    route: '/settings/appearance',
    icon: Icons.palette_outlined,
    keywords: '主题 模式 颜色 深色 浅色 背景 图片 模糊 字体 封面',
  ),
  SettingsSearchEntry(
    title: '主题模式',
    path: ['外观', '主题模式'],
    route: '/settings/appearance',
    icon: Icons.palette_outlined,
    keywords: '跟随系统 浅色 深色',
  ),
  SettingsSearchEntry(
    title: '主题色',
    path: ['外观', '主题色'],
    route: '/settings/appearance',
    icon: Icons.color_lens_outlined,
    keywords: '颜色 强调色',
  ),
  SettingsSearchEntry(
    title: '动态取色',
    path: ['外观', '动态取色'],
    route: '/settings/appearance',
    icon: Icons.auto_awesome_outlined,
    keywords: 'Material You 安卓12 系统颜色 壁纸取色',
  ),
  SettingsSearchEntry(
    title: '页面切换动画',
    path: ['外观', '页面切换动画'],
    route: '/settings/appearance',
    icon: Icons.animation,
    keywords: '转场 过渡 切换效果 平移 层叠 淡入淡出 slide stack fade 动画',
  ),
  SettingsSearchEntry(
    title: '自定义字体',
    path: ['外观', '自定义字体'],
    route: '/settings/appearance',
    icon: Icons.font_download_outlined,
    keywords: '字体 ttf otf 全局 文字 更换',
  ),
  SettingsSearchEntry(
    title: '自定义壁纸',
    path: ['外观', '自定义壁纸'],
    route: '/settings/appearance',
    icon: Icons.wallpaper_outlined,
    keywords: '壁纸 背景图 背景图片 更换 相册',
  ),
  SettingsSearchEntry(
    title: '播放详情页背景',
    path: ['外观', '播放详情页背景'],
    route: '/settings/appearance',
    icon: Icons.wallpaper_outlined,
    keywords: '封面模糊 壁纸模糊 氛围 自定义图片',
  ),
  SettingsSearchEntry(
    title: '详情页自定义图片',
    path: ['外观', '播放详情页背景', '详情页自定义图片'],
    route: '/settings/appearance',
    icon: Icons.image_outlined,
    keywords: '播放详情页 自定义图片 背景图 相册',
  ),
  SettingsSearchEntry(
    title: '自定义背景压暗遮罩',
    path: ['外观', '自定义背景压暗遮罩'],
    route: '/settings/appearance',
    icon: Icons.contrast_outlined,
    keywords: '遮罩 压暗 变暗 蒙版 暗色 自定义图片 壁纸',
  ),
  SettingsSearchEntry(
    title: '播放页封面样式',
    path: ['外观', '播放页封面样式'],
    route: '/settings/appearance',
    icon: Icons.album_outlined,
    keywords: '经典方形 圆形旋转 沉浸式 黑胶唱片 封面',
  ),
  SettingsSearchEntry(
    title: '黑胶唱针',
    path: ['外观', '播放页封面样式', '黑胶唱针'],
    route: '/settings/appearance',
    icon: Icons.graphic_eq_outlined,
    keywords: '唱针 唱臂 黑胶唱片 开关',
  ),
  SettingsSearchEntry(
    title: '歌单歌曲加载封面',
    path: ['外观', '歌单歌曲加载封面'],
    route: '/settings/appearance',
    icon: Icons.image_outlined,
    keywords: '歌单 列表 封面 加载 省流量',
  ),
  SettingsSearchEntry(
    title: '布局',
    path: ['布局'],
    route: '/settings/layout',
    icon: Icons.view_quilt_outlined,
    keywords: '顶栏 侧边栏 底栏 首页模块',
  ),
  SettingsSearchEntry(
    title: '侧边栏位置',
    path: ['布局', '顶栏布局', '侧边栏位置'],
    route: '/settings/layout',
    icon: Icons.swap_horiz_rounded,
    keywords: '左上 右上 菜单按钮',
  ),
  SettingsSearchEntry(
    title: '侧边栏布局',
    path: ['布局', '侧边栏布局'],
    route: '/settings/layout',
    icon: Icons.view_sidebar_outlined,
    keywords: '菜单 显示 隐藏 开关 拖拽 排序',
  ),
  SettingsSearchEntry(
    title: '自定义底栏',
    path: ['布局', '自定义底栏'],
    route: '/settings/bottom-bar',
    icon: Icons.view_compact_outlined,
    keywords: '底栏 导航栏 目的地 显示 隐藏 拖拽 排序',
  ),
  SettingsSearchEntry(
    title: '首页模块显示',
    path: ['布局', '首页模块'],
    route: '/settings/layout',
    icon: Icons.dashboard_customize_outlined,
    keywords: '首页 模块 显示 隐藏',
  ),
  SettingsSearchEntry(
    title: '歌词',
    path: ['歌词'],
    route: '/settings/lyrics',
    icon: Icons.lyrics_outlined,
    keywords: '歌词 翻译 罗马音 逐字 动效 对齐 字号 颜色 桌面歌词 蓝牙歌词 车载 推送',
  ),
  SettingsSearchEntry(
    title: '显示翻译',
    path: ['歌词', '显示翻译'],
    route: '/settings/lyrics',
    icon: Icons.translate_outlined,
    keywords: '翻译',
  ),
  SettingsSearchEntry(
    title: '显示罗马音',
    path: ['歌词', '显示罗马音'],
    route: '/settings/lyrics',
    icon: Icons.abc_rounded,
    keywords: '罗马音',
  ),
  SettingsSearchEntry(
    title: '逐字动效',
    path: ['歌词', '逐字动效'],
    route: '/settings/lyrics',
    icon: Icons.spellcheck_outlined,
    keywords: '逐字歌词 动画',
  ),
  SettingsSearchEntry(
    title: '显示位置',
    path: ['歌词', '显示位置'],
    route: '/settings/lyrics',
    icon: Icons.format_align_left_outlined,
    keywords: '对齐 左 中 右',
  ),
  SettingsSearchEntry(
    title: '歌词设置',
    path: ['歌词', '歌词设置'],
    route: '/settings/lyrics',
    icon: Icons.format_size_outlined,
    keywords: '字体 大小 歌词大小 颜色 已播 未播',
  ),
  SettingsSearchEntry(
    title: '单击歌词调整进度',
    path: ['歌词', '单击歌词调整进度'],
    route: '/settings/lyrics',
    icon: Icons.touch_app_outlined,
    keywords: '点击歌词 跳转 进度 seek',
  ),
  SettingsSearchEntry(
    title: '蓝牙歌词',
    path: ['歌词', '蓝牙歌词'],
    route: '/settings/lyrics',
    icon: Icons.bluetooth_audio_outlined,
    keywords: '蓝牙 车载 车机 推送 蓝牙歌词',
  ),
  SettingsSearchEntry(
    title: '桌面歌词',
    path: ['歌词', '桌面歌词'],
    route: '/settings/desktop-lyrics',
    icon: Icons.subtitles_outlined,
    keywords: '悬浮歌词 桌面歌词 浮窗 逐字效果',
  ),
  SettingsSearchEntry(
    title: '开启桌面歌词',
    path: ['歌词', '桌面歌词', '开启桌面歌词'],
    route: '/settings/desktop-lyrics',
    icon: Icons.subtitles_outlined,
    keywords: '桌面歌词 开关 悬浮窗 权限',
  ),
  SettingsSearchEntry(
    title: '软件内不显示桌面歌词',
    path: ['歌词', '桌面歌词', '软件内不显示桌面歌词'],
    route: '/settings/desktop-lyrics',
    icon: Icons.visibility_off_outlined,
    keywords: '应用内隐藏 界面内不显示 悬浮歌词',
  ),
  SettingsSearchEntry(
    title: '暂停时隐藏歌词',
    path: ['歌词', '桌面歌词', '暂停时隐藏歌词'],
    route: '/settings/desktop-lyrics',
    icon: Icons.pause_circle_outline,
    keywords: '暂停 隐藏 桌面歌词',
  ),
  SettingsSearchEntry(
    title: '显示逐字歌词效果',
    path: ['歌词', '桌面歌词', '显示逐字歌词效果'],
    route: '/settings/desktop-lyrics',
    icon: Icons.auto_awesome,
    keywords: '逐字 卡拉OK 桌面歌词 动画',
  ),
  SettingsSearchEntry(
    title: '不显示背景色',
    path: ['歌词', '桌面歌词', '不显示背景色'],
    route: '/settings/desktop-lyrics',
    icon: Icons.layers_clear_outlined,
    keywords: '透明 无背景 桌面歌词 底色',
  ),
  SettingsSearchEntry(
    title: '锁定桌面歌词',
    path: ['歌词', '桌面歌词', '锁定桌面歌词'],
    route: '/settings/desktop-lyrics',
    icon: Icons.lock_outline,
    keywords: '锁定 移动 拖动 桌面歌词',
  ),
  SettingsSearchEntry(
    title: '上下位置',
    path: ['歌词', '桌面歌词', '上下位置'],
    route: '/settings/desktop-lyrics',
    icon: Icons.vertical_align_center_rounded,
    keywords: '位置 高度 上下 桌面歌词',
  ),
  SettingsSearchEntry(
    title: '歌词样式',
    path: ['歌词', '桌面歌词', '歌词样式'],
    route: '/settings/desktop-lyrics',
    icon: Icons.palette_outlined,
    keywords: '颜色 背景 透明度 桌面歌词',
  ),
  SettingsSearchEntry(
    title: '歌词字号',
    path: ['歌词', '桌面歌词', '歌词字号'],
    route: '/settings/desktop-lyrics',
    icon: Icons.format_size_rounded,
    keywords: '字号 大小 桌面歌词',
  ),
  SettingsSearchEntry(
    title: '翻译字号',
    path: ['歌词', '桌面歌词', '翻译字号'],
    route: '/settings/desktop-lyrics',
    icon: Icons.text_fields_rounded,
    keywords: '翻译 字号 大小 桌面歌词',
  ),
  SettingsSearchEntry(
    title: '插件管理',
    path: ['插件管理'],
    route: '/settings/plugins',
    icon: Icons.extension_outlined,
    keywords: '插件 安装 启用 卸载 更新',
  ),
  SettingsSearchEntry(
    title: '在线安装',
    path: ['插件管理', '在线安装'],
    route: '/settings/plugins',
    icon: Icons.public_outlined,
    keywords: '插件地址 网络安装',
  ),
  SettingsSearchEntry(
    title: '本地导入插件',
    path: ['插件管理', '本地导入插件'],
    route: '/settings/plugins',
    icon: Icons.upload_file_outlined,
    keywords: 'js 文件 插件',
  ),
  SettingsSearchEntry(
    title: '插件用户变量',
    path: ['插件管理', '插件用户变量'],
    route: '/settings/plugins',
    icon: Icons.data_object_rounded,
    keywords: '变量 配置 参数 脚本',
  ),
  SettingsSearchEntry(
    title: '播放',
    path: ['播放'],
    route: '/settings/playback',
    icon: Icons.play_circle_outline_rounded,
    keywords: '音质 音量 并发 失败策略 常亮 浮窗',
  ),
  SettingsSearchEntry(
    title: '默认音质',
    path: ['播放', '默认音质'],
    route: '/settings/playback',
    icon: Icons.high_quality_outlined,
    keywords: '128k 192k 320k flac 无损',
  ),
  SettingsSearchEntry(
    title: '音量调节设置',
    path: ['播放', '音量调节设置'],
    route: '/settings/volume',
    icon: Icons.volume_up_outlined,
    keywords: '音量 音量键 滑块',
  ),
  SettingsSearchEntry(
    title: '应用内音量',
    path: ['播放', '音量调节设置', '应用内音量'],
    route: '/settings/volume',
    icon: Icons.volume_up,
    keywords: '音量 滑块',
  ),
  SettingsSearchEntry(
    title: '音量键调节应用内音量',
    path: ['播放', '音量调节设置', '音量键调节应用内音量'],
    route: '/settings/volume',
    icon: Icons.volume_up_rounded,
    keywords: '音量键 系统音量',
  ),
  SettingsSearchEntry(
    title: '播放歌曲时',
    path: ['播放', '播放歌曲时'],
    route: '/settings/playback',
    icon: Icons.queue_music_outlined,
    keywords: '入队 播放队列 整个列表 仅此歌曲 单曲',
  ),
  SettingsSearchEntry(
    title: '搜索并发数',
    path: ['播放', '搜索并发数'],
    route: '/settings/playback',
    icon: Icons.travel_explore_rounded,
    keywords: '搜索线程 并发 同时请求 平台 串行 全部并行',
  ),
  SettingsSearchEntry(
    title: '播放失败策略',
    path: ['播放', '播放失败策略'],
    route: '/settings/playback',
    icon: Icons.replay_rounded,
    keywords: '重试 换源 失败 跳过 优先重试次数 最大换源尝试次数',
  ),
  SettingsSearchEntry(
    title: '与其他应用同时播放',
    path: ['播放', '与其他应用同时播放'],
    route: '/settings/playback',
    icon: Icons.multitrack_audio_rounded,
    keywords: '不中断 同时播放 音频焦点',
  ),
  SettingsSearchEntry(
    title: '保持屏幕常亮',
    path: ['播放', '保持屏幕常亮'],
    route: '/settings/playback',
    icon: Icons.screen_lock_rotation_outlined,
    keywords: '不熄屏',
  ),
  SettingsSearchEntry(
    title: '迷你播放悬浮窗',
    path: ['播放', '迷你播放悬浮窗'],
    route: '/settings/playback',
    icon: Icons.picture_in_picture_alt_outlined,
    keywords: '浮窗 通知栏 迷你播放器',
  ),
  SettingsSearchEntry(
    title: '下载',
    path: ['下载'],
    route: '/settings/download',
    icon: Icons.download_outlined,
    keywords: '保存 路径 音质 歌词',
  ),
  SettingsSearchEntry(
    title: '下载路径',
    path: ['下载', '下载路径'],
    route: '/settings/download',
    icon: Icons.folder_outlined,
    keywords: '保存位置 目录',
  ),
  SettingsSearchEntry(
    title: '下载音质',
    path: ['下载', '下载音质'],
    route: '/settings/download',
    icon: Icons.download_outlined,
    keywords: '128k 192k 320k flac 无损',
  ),
  SettingsSearchEntry(
    title: '同时下载歌词',
    path: ['下载', '同时下载歌词'],
    route: '/settings/download',
    icon: Icons.lyrics_outlined,
    keywords: '歌词 下载',
  ),
  SettingsSearchEntry(
    title: '下载时写入元数据',
    path: ['下载', '下载时写入元数据'],
    route: '/settings/download',
    icon: Icons.edit_note_rounded,
    keywords: '元数据 标签 tag 封面 歌词 标题 写入音频',
  ),
  SettingsSearchEntry(
    title: '每次下载是否询问细节',
    path: ['下载', '每次下载是否询问细节'],
    route: '/settings/download',
    icon: Icons.tune_rounded,
    keywords: '询问 不询问 下载弹窗',
  ),
  // 任务管理入口在侧边栏，不在设置页层级内，用 note 标注来源。
  SettingsSearchEntry(
    title: '任务管理',
    path: ['任务管理'],
    route: '/settings/tasks',
    icon: Icons.task_alt_outlined,
    keywords: '批量任务 下载任务 任务列表 进度',
    note: '侧边栏入口',
  ),
  SettingsSearchEntry(
    title: '储存',
    path: ['储存'],
    route: '/settings/storage',
    icon: Icons.cleaning_services_outlined,
    keywords: '缓存 清理 空间 占用 封面 临时文件',
  ),
  SettingsSearchEntry(
    title: '封面缓存',
    path: ['储存', '封面缓存'],
    route: '/settings/storage',
    icon: Icons.image_outlined,
    keywords: '封面 图片缓存',
  ),
  SettingsSearchEntry(
    title: '播放流缓存',
    path: ['储存', '播放流缓存'],
    route: '/settings/storage',
    icon: Icons.play_circle_outline_rounded,
    keywords: '音频流 缓存 试听',
  ),
  SettingsSearchEntry(
    title: '下载中转文件',
    path: ['储存', '下载中转文件'],
    route: '/settings/storage',
    icon: Icons.download_outlined,
    keywords: '下载 临时 中转',
  ),
  SettingsSearchEntry(
    title: '临时文件',
    path: ['储存', '临时文件'],
    route: '/settings/storage',
    icon: Icons.folder_delete_outlined,
    keywords: '临时 temp',
  ),
  SettingsSearchEntry(
    title: '内存缓存',
    path: ['储存', '内存缓存'],
    route: '/settings/storage',
    icon: Icons.memory_rounded,
    keywords: '内存 图片内存',
  ),
  SettingsSearchEntry(
    title: '备份',
    path: ['备份'],
    route: '/settings/backup',
    icon: Icons.backup_outlined,
    keywords: '备份 恢复 导出 导入 迁移 换机 歌单 收藏',
  ),
  SettingsSearchEntry(
    title: '导出备份',
    path: ['备份', '导出备份'],
    route: '/settings/backup',
    icon: Icons.file_upload_outlined,
    keywords: '导出 备份文件 迁移 换机',
  ),
  SettingsSearchEntry(
    title: '导入备份',
    path: ['备份', '导入备份'],
    route: '/settings/backup',
    icon: Icons.file_download_outlined,
    keywords: '导入 恢复 备份文件 迁移 换机',
  ),
  SettingsSearchEntry(
    title: '日志',
    path: ['日志'],
    route: '/settings/logs',
    icon: Icons.description_outlined,
    keywords: '保存条数 日志时间范围 警告 报错 导出 崩溃记录 探针日志 清空 筛选',
  ),
  SettingsSearchEntry(
    title: '保存日志条数',
    path: ['日志', '保存日志条数'],
    route: '/settings/logs',
    icon: Icons.numbers_rounded,
    keywords: '条数 上限 保留',
  ),
  SettingsSearchEntry(
    title: '保存探针日志条数',
    path: ['日志', '保存探针日志条数'],
    route: '/settings/logs',
    icon: Icons.speed_rounded,
    keywords: '探针 配额',
  ),
  SettingsSearchEntry(
    title: '只记录警告和报错日志',
    path: ['日志', '只记录警告和报错日志'],
    route: '/settings/logs',
    icon: Icons.filter_alt_outlined,
    keywords: '警告 报错 error warn 筛选',
  ),
  SettingsSearchEntry(
    title: '崩溃记录',
    path: ['日志', '崩溃记录'],
    route: '/settings/logs',
    icon: Icons.bug_report_outlined,
    keywords: '闪退 崩溃 crash 20 份',
  ),
  SettingsSearchEntry(
    title: '日志时间范围',
    path: ['日志', '日志时间范围'],
    route: '/settings/logs',
    icon: Icons.date_range_outlined,
    keywords: '时间 范围 筛选',
  ),
  SettingsSearchEntry(
    title: '导出全部日志',
    path: ['日志', '导出全部日志'],
    route: '/settings/logs',
    icon: Icons.file_upload_outlined,
    keywords: '导出 全部 日志',
  ),
  SettingsSearchEntry(
    title: '导出错误日志',
    path: ['日志', '导出错误日志'],
    route: '/settings/logs',
    icon: Icons.error_outline_rounded,
    keywords: '导出 错误 error',
  ),
  SettingsSearchEntry(
    title: '一键清空日志',
    path: ['日志', '一键清空日志'],
    route: '/settings/logs',
    icon: Icons.delete_sweep_outlined,
    keywords: '清空 删除 日志',
  ),
  SettingsSearchEntry(
    title: '问题反馈',
    path: ['问题反馈'],
    route: '/settings/feedback',
    icon: Icons.feedback_outlined,
    keywords: '功能建议 提交问题 我的反馈 上传图片 日志',
  ),
  SettingsSearchEntry(
    title: '支持开发者',
    path: ['支持开发者'],
    route: '/settings/sponsor',
    icon: Icons.favorite_outline_rounded,
    keywords: '赞助 打赏 收款码 微信 支付宝',
  ),
  SettingsSearchEntry(
    title: '关于',
    path: ['关于'],
    route: '/settings/about',
    icon: Icons.info_outline,
    keywords: '关于 版本 开源 许可 仓库 项目仓库 官网 检查更新 第三方许可 创作者',
  ),
  SettingsSearchEntry(
    title: '检查更新',
    path: ['关于', '检查更新'],
    route: '/settings/about',
    icon: Icons.system_update_alt_rounded,
    keywords: '更新 版本 升级',
  ),
  SettingsSearchEntry(
    title: '项目仓库',
    path: ['关于', '项目仓库'],
    route: '/settings/about',
    icon: Icons.source_outlined,
    keywords: 'github 源码 仓库',
  ),
  SettingsSearchEntry(
    title: '软件官网',
    path: ['关于', '软件官网'],
    route: '/settings/about',
    icon: Icons.language_rounded,
    keywords: '官网 网站 xymusic.cc',
  ),
  SettingsSearchEntry(
    title: '第三方许可',
    path: ['关于', '第三方许可'],
    route: '/settings/about',
    icon: Icons.article_outlined,
    keywords: '开源 许可 license 致谢',
  ),
  SettingsSearchEntry(
    title: '其他',
    path: ['其他'],
    route: '/settings/other',
    icon: Icons.tune_rounded,
    keywords: '统计 电池 保活',
  ),
  SettingsSearchEntry(
    title: '听歌统计',
    path: ['其他', '听歌统计'],
    route: '/settings/statistics',
    icon: Icons.query_stats_outlined,
    keywords: '播放次数 时长 历史',
  ),
  SettingsSearchEntry(
    title: '后台播放保活',
    path: ['其他', '后台播放保活'],
    route: '/settings/other',
    icon: Icons.battery_saver_outlined,
    keywords: '电池优化 省电 白名单 华为 荣耀 后台被杀 中断播放',
  ),
  // 扫描文件夹/扫描格式/排除短音频已并入「音乐库 → 本地音乐」右上角的
  // 扫描目录设置页，搜索直达该页。
  SettingsSearchEntry(
    title: '扫描文件夹',
    path: ['音乐库', '本地音乐', '扫描文件夹'],
    route: '/settings/scan-folders',
    icon: Icons.folder_special_outlined,
    keywords: '添加目录 本地音乐',
    note: '音乐库页入口',
  ),
  SettingsSearchEntry(
    title: '扫描格式',
    path: ['音乐库', '本地音乐', '扫描文件夹', '扫描格式'],
    route: '/settings/scan-folders',
    icon: Icons.audiotrack_outlined,
    keywords: 'flac mp3 wav aac m4a ogg aiff',
    note: '音乐库页入口',
  ),
  SettingsSearchEntry(
    title: '排除短音频',
    path: ['音乐库', '本地音乐', '扫描文件夹', '排除短音频'],
    route: '/settings/scan-folders',
    icon: Icons.timer_outlined,
    keywords: '最短时长 秒',
    note: '音乐库页入口',
  ),
];

List<SettingsSearchEntry> searchSettings(String rawQuery) {
  final query = rawQuery.toLowerCase().replaceAll(RegExp(r'\s+'), '');
  if (query.isEmpty) return const [];
  int matchRank(SettingsSearchEntry entry) {
    final title = entry.title.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    final path = entry.path
        .join('')
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), '');
    final keywords = entry.keywords.toLowerCase().replaceAll(
      RegExp(r'\s+'),
      '',
    );
    if (title == query) return 0;
    if (title.startsWith(query)) return 1;
    if (title.contains(query)) return 2;
    if (path.contains(query)) return 3;
    if (keywords.contains(query)) return 4;
    return 99;
  }

  final results = settingsSearchEntries
      .where((entry) => matchRank(entry) < 99)
      .toList();
  results.sort((a, b) {
    final levelOrder = a.level.compareTo(b.level);
    if (levelOrder != 0) return levelOrder;
    final rankOrder = matchRank(a).compareTo(matchRank(b));
    if (rankOrder != 0) return rankOrder;
    return a.title.compareTo(b.title);
  });
  return results;
}

/// 根页设置类目：按「个性化 / 音乐 / 应用」三块组织（对齐参考实现
/// CurrentMusicX 的 SettingsScreen 分组），每块是一张常显卡片。
enum _SettingsCategory {
  personalization('个性化', Icons.auto_awesome_outlined),
  music('音乐', Icons.library_music_outlined),
  app('应用', Icons.widgets_outlined);

  const _SettingsCategory(this.label, this.icon);

  final String label;
  final IconData icon;
}

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key, this.section = SettingsSection.root});

  final SettingsSection section;

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  bool _exportingBackup = false;
  bool _importingBackup = false;

  /// 悬浮头部（搜索框）的测量 Key 与实测高度：搜索框悬浮于设置列表
  /// 上方，列表内容滚动时从毛玻璃下方穿过被模糊（与列表浮动按钮组
  /// 同款观感），列表顶部让出头部高度。
  final GlobalKey _floatingHeaderKey = GlobalKey();
  double _floatingHeaderExtent = 70;

  /// 布局完成后用真实高度修正悬浮头部占位，字体缩放等场景自动适配。
  void _measureFloatingHeader() {
    if (!mounted) return;
    // 直接读 currentContext.size 会在渲染对象尚未完成布局时抛
    // 「RenderBox was not laid out」（首帧/字体缩放重建时偶发），
    // 因此先取 RenderObject 并显式判断 hasSize。
    final renderObject = _floatingHeaderKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return;
    final size = renderObject.size;
    if (size.height <= 0) return;
    if ((size.height - _floatingHeaderExtent).abs() > 0.5) {
      setState(() => _floatingHeaderExtent = size.height);
    }
  }

  SettingsSection get section => widget.section;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// 导出前先弹勾选框：仅收藏 / 歌单 / 插件 / 设置四类可勾选，
  /// 最近播放、听歌统计、下载记录等其余数据一律不进备份。
  Future<BackupExportOptions?> _showBackupOptionsDialog() {
    var favorites = true;
    var playlists = true;
    var plugins = true;
    var settings = true;
    return showDialog<BackupExportOptions>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('选择备份内容'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CheckboxListTile(
                value: favorites,
                onChanged: (value) =>
                    setDialogState(() => favorites = value ?? false),
                title: const Text('收藏'),
                subtitle: const Text('收藏的歌曲与排序'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
              ),
              CheckboxListTile(
                value: playlists,
                onChanged: (value) =>
                    setDialogState(() => playlists = value ?? false),
                title: const Text('歌单'),
                subtitle: const Text('全部歌单及其歌曲'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
              ),
              CheckboxListTile(
                value: plugins,
                onChanged: (value) =>
                    setDialogState(() => plugins = value ?? false),
                title: const Text('插件'),
                subtitle: const Text('插件脚本与用户变量'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
              ),
              CheckboxListTile(
                value: settings,
                onChanged: (value) =>
                    setDialogState(() => settings = value ?? false),
                title: const Text('设置'),
                subtitle: const Text('全部设置与主题、壁纸、字体'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: favorites || playlists || plugins || settings
                  ? () => Navigator.pop(
                      dialogContext,
                      BackupExportOptions(
                        favorites: favorites,
                        playlists: playlists,
                        plugins: plugins,
                        settings: settings,
                      ),
                    )
                  : null,
              child: const Text('导出'),
            ),
          ],
        ),
      ),
    );
  }

  /// 导出本地数据（按勾选项：收藏、歌单、插件、设置与主题）到
  /// 用户选择的 JSON 文件。
  Future<void> _exportBackup() async {
    if (_exportingBackup) return;
    final options = await _showBackupOptionsDialog();
    if (!mounted || options == null) return;
    setState(() => _exportingBackup = true);
    try {
      final path = await const BackupService().exportBackup(options: options);
      if (!mounted || path == null) return;
      XyNotice.show(context, message: '备份已导出');
    } catch (error) {
      if (mounted) {
        XyNotice.show(
          context,
          message: '导出备份失败：$error',
          type: XyNoticeType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _exportingBackup = false);
    }
  }

  /// 选择备份文件 → 校验 → 用户确认 → 写入 prefs 与插件脚本。
  Future<void> _importBackup() async {
    if (_importingBackup) return;
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (!mounted || picked == null || picked.files.isEmpty) return;
    final filePath = picked.files.single.path;
    if (filePath == null) {
      XyNotice.show(context, message: '无法读取所选文件', type: XyNoticeType.error);
      return;
    }
    setState(() => _importingBackup = true);
    try {
      final service = const BackupService();
      // 已启用插件列表：v5 备份里无 XY 私有 path 的网络条目（外部
      // 格式转换工具产出）按平台匹配插件重建。
      final plugins = await ref.read(enabledMusicPluginsProvider.future);
      final data = await service.readBackup(
        filePath,
        enabledPlugins: plugins,
      );
      if (!mounted) return;
      final exportedAt = data.exportedAt.isNotEmpty
          ? data.exportedAt.replaceFirst('T', ' ').split('.').first
          : '未知时间';
      final libraryInfo = data.librarySongCount > 0
          ? '与 ${data.librarySongCount} 首本地曲库'
          : '';
      final appearanceInfo = data.appearance.isEmpty
          ? ''
          : '、外观自定义文件（壁纸/字体）';
      // v5 备份（仿 MusicFree 结构）直接展示歌单与歌曲数。
      final sheetInfo = data.sheetCount > 0
          ? '${data.sheetCount} 个歌单/收藏（共 ${data.songCount} 首）、'
          : '${data.prefCount} 项数据、';
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('导入备份？'),
          content: Text(
            '备份导出于 $exportedAt，包含 '
            '$sheetInfo${data.pluginCount} 个插件'
            '$libraryInfo$appearanceInfo。\n\n'
            '导入将覆盖当前同名的歌单、收藏、插件、本地曲库与设置，'
            '建议先停止播放后继续。最近播放与听歌统计不受备份影响。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('导入'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
      await service.applyBackup(data);
      // 备份可能带回自定义字体文件（v3 起）：立即注册让字体无需重启
      // 即可生效（文件缺失或损坏时 loadCustomFont 静默返回 false）。
      if (data.appearance.font != null) {
        await loadCustomFont(await customFontFilePath());
      }
      // 设置/主题在 provider 重建后立即生效；曲库表已整体写回 SQLite，
      // invalidate 后曲库页即时刷新；歌单、收藏、最近播放与插件列表原先
      // 由各 provider 在内存中持有快照且仅在启动时加载一次，导入后必须
      // 一并 invalidate 重建，否则「我的收藏」等页面会继续显示旧的
      // （空的）内存状态。
      ref.invalidate(settingsProvider);
      ref.invalidate(favoritesProvider);
      ref.invalidate(playlistsProvider);
      ref.invalidate(recentSongsProvider);
      ref.invalidate(enabledMusicPluginsProvider);
      if (data.librarySongCount > 0) ref.invalidate(libraryProvider);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('导入完成'),
          content: const Text(
            '设置与主题已生效；本地曲库已恢复；歌单与收藏已恢复。',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    } on BackupException catch (error) {
      if (mounted) {
        XyNotice.show(
          context,
          message: error.message,
          type: XyNoticeType.error,
        );
      }
    } catch (error) {
      if (mounted) {
        XyNotice.show(
          context,
          message: '导入备份失败：$error',
          type: XyNoticeType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _importingBackup = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider).valueOrNull;
    final notifier = ref.read(settingsProvider.notifier);
    final auth = ref.watch(authProvider);
    final dynamicColorSupported = ref.watch(dynamicColorSupportedProvider);

    // 根页改为卡片流：入口型分类（账号/插件管理/备份与恢复/存储与
    // 缓存/问题反馈）做成无图标卡片，点击进入独立页面；其余分类的
    // 名称写在大框上方，内容直接内嵌展示，不再跳转子页。
    final children = section == SettingsSection.root
        ? _rootCards(
            context,
            settings: settings,
            notifier: notifier,
            auth: auth,
            dynamicColorSupported: dynamicColorSupported,
          )
        : _sectionTiles(
            context,
            section: section,
            settings: settings,
            notifier: notifier,
            auth: auth,
            dynamicColorSupported: dynamicColorSupported,
          );

    // 布局完成后修正悬浮头部占位高度。
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _measureFloatingHeader(),
    );

    return Scaffold(
      // 页面底保持透明（露出应用背景层）：半透明只做在类目卡片上
      //（见 [_categoryCard] / [_flatCard]），不做整页半透明。
      appBar: AppBar(
        automaticallyImplyLeading:
            section != SettingsSection.root ||
            settings?.sidebarPosition != SidebarPosition.right,
        leading:
            section == SettingsSection.root &&
                settings?.sidebarPosition != SidebarPosition.right
            ? const AppSidebarMenuButton()
            : null,
        title: Text(_pageTitle),
        actions: [
          if (section == SettingsSection.root &&
              settings?.sidebarPosition == SidebarPosition.right)
            const AppSidebarMenuButton(),
        ],
      ),
      // 搜索框悬浮于设置列表上方：列表内容滚动时从毛玻璃下方穿过被
      // 模糊，与列表浮动按钮组观感一致。
      body: Stack(
        children: [
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.only(
                top: section == SettingsSection.root
                    ? _floatingHeaderExtent
                    : 0,
              ),
              child: ListView(
                padding: EdgeInsets.only(
                  top: 6,
                  // 消费 Shell 注入的悬浮底栏/播放栏高度（padding.bottom），
                  // 否则布局页等底部的设置项会被自定义底栏盖住。
                  bottom: 24 + MediaQuery.paddingOf(context).bottom,
                ),
                children: [
                  if (section == SettingsSection.root &&
                      _query.isNotEmpty)
                    ..._searchResultTiles(context),
                  if (section != SettingsSection.root || _query.isEmpty)
                    ...children,
                ],
              ),
            ),
          ),
          if (section == SettingsSection.root)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: KeyedSubtree(
                key: _floatingHeaderKey,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                  child: FrostedSearchField(
                    controller: _searchController,
                    hintText: '搜索设置',
                    onChanged: (value) => setState(() => _query = value.trim()),
                    showClearSuffix: true,
                    onCleared: () {
                      _searchController.clear();
                      setState(() => _query = '');
                    },
                    padding: EdgeInsets.zero,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 各分类的设置项列表：根页内嵌卡片与子页面（搜索结果直达）共用。
  List<Widget> _sectionTiles(
    BuildContext context, {
    required SettingsSection section,
    required AppSettings? settings,
    required SettingsNotifier notifier,
    required AuthState auth,
    required AsyncValue<bool> dynamicColorSupported,
  }) {
    return switch (section) {
      // 根页内容由 _rootCards 组装（含内嵌分类卡片），不走此列表。
      SettingsSection.root => const [],
      SettingsSection.account => [
        _tile(
          context,
          icon: Icons.account_circle,
          title: '账号与安全',
          trailing: Text(
            auth.isLoggedIn ? auth.user!.nickname : '未登录',
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          onTap: () => context.push('/account?from=settings'),
        ),
      ],
      SettingsSection.appearance => [
        _tile(
          context,
          icon: Icons.palette,
          title: '主题模式',
          trailing: _themeLabel(settings),
          onTap: () => _pickThemeMode(context, ref, settings),
        ),
        _tile(
          context,
          icon: Icons.color_lens,
          title: '主题色',
          trailing: _ColorDot(
            color: Color(settings?.accentColor ?? 0xFFEC4141),
          ),
          onTap: () => _pickAccentColor(context, ref, settings),
        ),
        _tile(
          context,
          icon: Icons.animation,
          title: '页面切换动画',
          trailing: DropdownButtonHideUnderline(
            child: DropdownButton<PageTransitionMode>(
              value:
                  settings?.pageTransitionMode ?? PageTransitionMode.fade,
              isDense: true,
              alignment: AlignmentDirectional.centerEnd,
              items: PageTransitionMode.values
                  .map(
                    (mode) => DropdownMenuItem<PageTransitionMode>(
                      value: mode,
                      child: Text(_pageTransitionModeLabel(mode)),
                    ),
                  )
                  .toList(),
              onChanged: (mode) {
                if (mode != null) {
                  unawaited(
                    ref
                        .read(settingsProvider.notifier)
                        .setPageTransitionMode(mode),
                  );
                }
              },
            ),
          ),
        ),
        _dynamicColorTile(
          context,
          settings: settings,
          supported: dynamicColorSupported.valueOrNull == true,
          loading: dynamicColorSupported.isLoading,
          onChanged: (value) => notifier.setDynamicColor(value),
        ),
        _tile(
          context,
          icon: Icons.font_download_outlined,
          title: '自定义字体',
          trailing: Text(
            settings?.fontFamily.trim().isNotEmpty == true ? '已启用' : '默认',
          ),
          onTap: () => _editCustomFont(context, ref),
        ),
        _tile(
          context,
          icon: Icons.wallpaper_outlined,
          title: '自定义壁纸',
          trailing: Text(
            settings?.customBackgroundPath.trim().isNotEmpty == true
                ? '已启用'
                : '未设置',
          ),
          onTap: () => _editCustomBackground(context, ref, settings),
        ),
        _tile(
          context,
          icon: Icons.wallpaper_outlined,
          title: '播放详情页背景',
          trailing: DropdownButtonHideUnderline(
            child: DropdownButton<PlayerDetailBackgroundMode>(
              value:
                  settings?.playerDetailBackgroundMode ??
                  PlayerDetailBackgroundMode.flowingLight,
              isDense: true,
              alignment: AlignmentDirectional.centerEnd,
              // 封面模糊与粒子动效选项已移除，仅展示其余背景模式。
              items: PlayerDetailBackgroundMode.values
                  .where(
                    (mode) =>
                        mode != PlayerDetailBackgroundMode.coverBlur &&
                        mode != PlayerDetailBackgroundMode.particle,
                  )
                  .map(
                    (mode) => DropdownMenuItem<PlayerDetailBackgroundMode>(
                      value: mode,
                      child: Text(_playerDetailBackgroundLabel(mode)),
                    ),
                  )
                  .toList(),
              onChanged: (mode) {
                if (mode != null) {
                  unawaited(_setPlayerDetailBackground(context, ref, mode));
                }
              },
            ),
          ),
        ),
        _tile(
          context,
          icon: Icons.image_outlined,
          title: '详情页自定义图片',
          trailing: Text(
            settings?.playerDetailCustomImagePath.trim().isNotEmpty == true
                ? '已设置'
                : '未设置',
          ),
          onTap: () => _pickPlayerDetailImage(context, ref),
        ),
        _switchTile(
          context,
          icon: Icons.contrast_outlined,
          title: '自定义背景压暗遮罩',
          subtitle: '关闭后自定义图片/壁纸背景不再叠加暗色遮罩（纯色背景不变暗）',
          value: settings?.playerDetailBackgroundDim ?? true,
          onChanged: (value) => unawaited(
            ref
                .read(settingsProvider.notifier)
                .setPlayerDetailBackgroundDim(value),
          ),
        ),
        _tile(
          context,
          icon: Icons.album_outlined,
          title: '播放页封面样式',
          trailing: DropdownButtonHideUnderline(
            child: DropdownButton<PlayerCoverStyle>(
              value: settings?.playerCoverStyle ?? PlayerCoverStyle.classic,
              isDense: true,
              alignment: AlignmentDirectional.centerEnd,
              items: PlayerCoverStyle.values
                  .map(
                    (style) => DropdownMenuItem<PlayerCoverStyle>(
                      value: style,
                      child: Text(_playerCoverStyleLabel(style)),
                    ),
                  )
                  .toList(),
              onChanged: (style) {
                if (style != null) {
                  unawaited(
                    ref
                        .read(settingsProvider.notifier)
                        .setPlayerCoverStyle(style),
                  );
                }
              },
            ),
          ),
        ),
        if (settings?.playerCoverStyle == PlayerCoverStyle.vinyl)
          _switchTile(
            context,
            icon: Icons.graphic_eq_outlined,
            title: '黑胶唱针',
            subtitle: '在黑胶唱片封面右上角显示经典款唱针',
            value: settings?.vinylTonearm ?? true,
            onChanged: (value) => unawaited(
              ref.read(settingsProvider.notifier).setVinylTonearm(value),
            ),
          ),
        // 歌单封面开关直接放在本页，不再进下一级页面。
        _switchTile(
          context,
          icon: Icons.image_outlined,
          title: '歌单歌曲加载封面',
          subtitle: '关闭后歌单列表不再为歌曲拉取封面，省流量与内存',
          value: settings?.showPlaylistSongCovers ?? true,
          onChanged: (v) => notifier.setShowPlaylistSongCovers(v),
        ),
      ],
      SettingsSection.layout => [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            '顶栏布局',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
        _tile(
          context,
          icon: Icons.swap_horiz_rounded,
          title: '侧边栏位置',
          trailing: Text(
            settings?.sidebarPosition == SidebarPosition.right ? '右上' : '左上',
          ),
          onTap: () => _pickSidebarPosition(context, ref, settings),
        ),
        // 侧边栏布局编辑器并入本页（原「侧边栏布局」独立页面）。
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
          child: Text(
            '侧边栏布局',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
        _SidebarLayoutEditor(
          settings: settings ?? const AppSettings(),
          notifier: notifier,
        ),
        _categoryTile(
          context,
          title: '自定义底栏',
          subtitle: '挑选底栏目的地并拖动排序',
          route: '/settings/bottom-bar',
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
          child: Text(
            '首页模块',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
        _tile(
          context,
          icon: Icons.dashboard_customize_outlined,
          title: '首页模块显示',
          trailing: Text(
            '${settings?.homeModules.length ?? kDefaultHomeModules.length}'
            '/${kAllHomeModules.length}',
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          onTap: () => showModalBottomSheet<void>(
            context: context,
            // 根 Navigator：模块面板覆盖悬浮底栏，避免底部开关被底栏遮挡。
            useRootNavigator: true,
            showDragHandle: true,
            builder: (_) => const _HomeModulesSheet(),
          ),
        ),
      ],
      SettingsSection.sidebarLayout => [
        _SidebarLayoutEditor(
          settings: settings ?? const AppSettings(),
          notifier: notifier,
        ),
      ],
      SettingsSection.bottomBar => [
        _BottomBarLayoutEditor(
          settings: settings ?? const AppSettings(),
          notifier: notifier,
        ),
      ],
      SettingsSection.playback => [
        _tile(
          context,
          icon: Icons.high_quality,
          title: '默认音质',
          trailing: Text(
            qualityDisplayLabel(settings?.onlineDefaultQuality ?? '320k'),
          ),
          onTap: () => _pickQuality(context, ref, settings, isOnline: true),
        ),
        _categoryTile(
          context,
          title: '音量调节设置',
          subtitle: '应用内音量滑块、音量键是否只调本应用音量',
          route: '/settings/volume',
        ),
        _tile(
          context,
          icon: Icons.queue_music_rounded,
          title: '播放歌曲时',
          trailing: DropdownButtonHideUnderline(
            child: DropdownButton<PlaySongQueueMode>(
              value:
                  settings?.playSongQueueMode ?? PlaySongQueueMode.wholeList,
              isDense: true,
              alignment: AlignmentDirectional.centerEnd,
              // 折叠态用短标签，展开菜单用完整说明，避免长文案撑破行。
              selectedItemBuilder: (context) => [
                for (final mode in PlaySongQueueMode.values)
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: Text(_playSongQueueModeLabel(mode, short: true)),
                  ),
              ],
              items: PlaySongQueueMode.values
                  .map(
                    (mode) => DropdownMenuItem<PlaySongQueueMode>(
                      value: mode,
                      child: Text(_playSongQueueModeLabel(mode)),
                    ),
                  )
                  .toList(),
              onChanged: (mode) {
                if (mode != null) {
                  unawaited(
                    ref
                        .read(settingsProvider.notifier)
                        .setPlaySongQueueMode(mode),
                  );
                }
              },
            ),
          ),
        ),
        _tile(
          context,
          icon: Icons.travel_explore_rounded,
          title: '搜索并发数',
          trailing: DropdownButtonHideUnderline(
            child: DropdownButton<int>(
              value: (settings?.searchConcurrency ?? 0).clamp(0, 5),
              isDense: true,
              alignment: AlignmentDirectional.centerEnd,
              items: [
                for (var i = 0; i <= 5; i++)
                  DropdownMenuItem<int>(
                    value: i,
                    child: Text(_searchConcurrencyLabel(i)),
                  ),
              ],
              onChanged: (value) {
                if (value != null) {
                  unawaited(
                    ref
                        .read(settingsProvider.notifier)
                        .setSearchConcurrency(value),
                  );
                }
              },
            ),
          ),
        ),
        _tile(
          context,
          icon: Icons.replay_rounded,
          title: '播放失败策略',
          trailing: Text(
            '重试 ${settings?.playbackRetryCount ?? 0} · '
            '换源 ${settings?.playbackSwitchSourceCount ?? 0}',
          ),
          onTap: () => _showPlaybackFailurePolicy(context),
        ),
        _switchTile(
          context,
          icon: Icons.multitrack_audio_rounded,
          title: '与其他应用同时播放',
          subtitle: '开启后播放其它应用的音频不会中断本应用播放',
          value: settings?.playOtherAudioWithoutInterruption ?? false,
          onChanged: (value) =>
              notifier.setPlayOtherAudioWithoutInterruption(value),
        ),
        _switchTile(
          context,
          icon: Icons.screen_lock_rotation,
          title: '保持屏幕常亮',
          subtitle: '仅在播放页显示并处于前台时生效；关闭后按系统息屏时间自动熄屏，耗电可降一个量级',
          value: settings?.keepScreenOn ?? false,
          onChanged: (v) => notifier.setKeepScreenOn(v),
        ),
        _switchTile(
          context,
          icon: Icons.picture_in_picture_alt_outlined,
          title: '迷你播放悬浮窗',
          subtitle: '通知栏单击媒体卡片弹出浮窗，封面/进度条/切歌按钮可直接操作',
          value: settings?.miniPlayerOverlayEnabled ?? false,
          onChanged: (v) => _setMiniPlayerOverlay(context, ref, v),
        ),
      ],
      // 「音量调节设置」三级页：从「音乐 › 播放」进入。
      SettingsSection.volume => [
        _tile(
          context,
          icon: Icons.volume_up,
          title: '应用内音量',
          trailing: _volumeSlider(settings, notifier),
        ),
        _switchTile(
          context,
          icon: Icons.volume_up_rounded,
          title: '音量键调节应用内音量',
          subtitle: '应用前台时音量键只调本应用音量，不影响系统媒体音量',
          value: settings?.volumeKeyControlsAppVolume ?? true,
          onChanged: (v) => notifier.setVolumeKeyControlsAppVolume(v),
        ),
      ],
      // 内容已全部并入「个性化 › 歌词」页；保留空分支以兼容旧路由。
      SettingsSection.playbackDetail => const [],
      SettingsSection.lyrics => [
        // 歌词显示
        _switchTile(
          context,
          icon: Icons.translate,
          title: '显示翻译',
          value: settings?.showLyricsTranslation ?? true,
          onChanged: (v) => notifier.setShowLyricsTranslation(v),
        ),
        _switchTile(
          context,
          icon: Icons.abc_rounded,
          title: '显示罗马音',
          value: settings?.showLyricsRomaji ?? true,
          onChanged: (v) => notifier.setShowLyricsRomaji(v),
        ),
        _tile(
          context,
          icon: Icons.spellcheck,
          title: '逐字动效',
          trailing: DropdownButtonHideUnderline(
            child: DropdownButton<LyricWordEffectMode>(
              value:
                  settings?.lyricWordEffectMode ??
                  LyricWordEffectMode.progressive,
              isDense: true,
              alignment: AlignmentDirectional.centerEnd,
              items: LyricWordEffectMode.values
                  .map(
                    (mode) => DropdownMenuItem<LyricWordEffectMode>(
                      value: mode,
                      child: Text(_lyricWordEffectLabel(mode)),
                    ),
                  )
                  .toList(),
              onChanged: (mode) {
                if (mode != null) notifier.setLyricWordEffectMode(mode);
              },
            ),
          ),
        ),
        _tile(
          context,
          icon: Icons.format_align_left,
          title: '显示位置',
          trailing: DropdownButtonHideUnderline(
            child: DropdownButton<LyricDisplayAlignment>(
              value:
                  settings?.lyricDisplayAlignment ?? LyricDisplayAlignment.left,
              isDense: true,
              alignment: AlignmentDirectional.centerEnd,
              items: LyricDisplayAlignment.values
                  .map(
                    (alignment) => DropdownMenuItem<LyricDisplayAlignment>(
                      value: alignment,
                      child: Text(_lyricDisplayAlignmentLabel(alignment)),
                    ),
                  )
                  .toList(),
              onChanged: (alignment) {
                if (alignment != null) {
                  notifier.setLyricDisplayAlignment(alignment);
                }
              },
            ),
          ),
        ),
        _tile(
          context,
          icon: Icons.format_size_outlined,
          title: '歌词设置',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _desktopColorDot(
                context,
                settings?.playerLyricPlayedColor ?? kDefaultPlayerLyricPlayedColor,
              ),
              const SizedBox(width: 4),
              _desktopColorDot(
                context,
                settings?.playerLyricUnplayedColor ??
                    kDefaultPlayerLyricUnplayedColor,
              ),
              const SizedBox(width: 6),
              Text(
                '${(settings?.lyricFontSize ?? 22.0).toStringAsFixed(0)}号',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          // 与播放详情页更多菜单共用同一歌词设置底部面板。
          onTap: () => unawaited(showLyricSettingsSheet(context)),
        ),
        // 播放详情页歌词行为（原「播放」下一级页面）。
        _switchTile(
          context,
          icon: Icons.touch_app_outlined,
          title: '单击歌词调整进度',
          value: settings?.lyricTapSeek ?? true,
          onChanged: (v) => notifier.setLyricTapSeek(v),
        ),
        // 蓝牙歌词：开关入口已从播放详情页更多菜单移入本页，复用共用桥接
        // 逻辑（开启会拉起原生蓝牙权限，未授权不写设置）。
        _switchTile(
          context,
          icon: Icons.bluetooth_audio_outlined,
          title: '蓝牙歌词',
          subtitle: '通过蓝牙把歌词推送到车机屏幕，开启需授予蓝牙权限',
          value: settings?.bluetoothLyricsEnabled ?? false,
          onChanged: (next) => applyBluetoothLyricsEnabled(context, ref, next),
        ),
        _categoryTile(
          context,
          title: '桌面歌词',
          subtitle: '桌面歌词开关、样式、字号与位置',
          route: '/settings/desktop-lyrics',
        ),
      ],
      SettingsSection.desktopLyrics => [
        _switchTile(
          context,
          icon: Icons.subtitles_outlined,
          title: '开启桌面歌词',
          value: settings?.desktopLyricsEnabled ?? false,
          onChanged: (value) => _setDesktopLyrics(context, ref, value),
        ),
        _switchTile(
          context,
          icon: Icons.visibility_off_outlined,
          title: '软件内不显示桌面歌词',
          value: settings?.desktopLyricsHideInApp ?? true,
          onChanged: (value) => notifier.setDesktopLyricsHideInApp(value),
        ),
        _switchTile(
          context,
          icon: Icons.pause_circle_outline,
          title: '暂停时隐藏歌词',
          subtitle: '播放暂停时隐藏桌面歌词内容，恢复播放后重新显示',
          value: settings?.desktopLyricsHideOnPause ?? false,
          onChanged: (value) => notifier.setDesktopLyricsHideOnPause(value),
        ),
        _switchTile(
          context,
          icon: Icons.auto_awesome,
          title: '显示逐字歌词效果',
          value: settings?.desktopLyricsShowWordEffect ?? true,
          onChanged: (value) => notifier.setDesktopLyricsShowWordEffect(value),
        ),
        _switchTile(
          context,
          icon: Icons.layers_clear_outlined,
          title: '不显示背景色',
          value: settings?.desktopLyricsNoBackground ?? true,
          onChanged: (value) => notifier.setDesktopLyricsNoBackground(value),
        ),
        _switchTile(
          context,
          icon: Icons.lock_outline,
          title: '锁定桌面歌词',
          value: settings?.desktopLyricsLocked ?? false,
          onChanged: (value) => notifier.setDesktopLyricsLocked(value),
        ),
        _desktopLyricsPositionTile(context, settings, notifier),
        _tile(
          context,
          icon: Icons.palette_outlined,
          title: '歌词样式',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _desktopColorDot(
                context,
                settings?.desktopLyricsLyricColor ?? 0xFFFFFFFF,
              ),
              const SizedBox(width: 4),
              _desktopColorDot(
                context,
                settings?.desktopLyricsTranslationColor ?? 0xFFE1E1E6,
              ),
              const SizedBox(width: 4),
              _desktopColorDot(
                context,
                settings?.desktopLyricsBackgroundColor ?? 0xFF18181C,
              ),
            ],
          ),
          onTap: () => showDialog<void>(
            context: context,
            builder: (_) => const _DesktopLyricsStyleSheet(),
          ),
        ),
        _tile(
          context,
          icon: Icons.format_size_rounded,
          title: '歌词字号',
          trailing: _desktopLyricsFontSizeControl(
            value: settings?.desktopLyricsLyricFontSize ?? 24,
            min: 16,
            max: 40,
            onChanged: notifier.setDesktopLyricsLyricFontSize,
          ),
        ),
        _tile(
          context,
          icon: Icons.text_fields_rounded,
          title: '翻译字号',
          trailing: _desktopLyricsFontSizeControl(
            value: settings?.desktopLyricsTranslationFontSize ?? 12,
            min: 10,
            max: 28,
            onChanged: notifier.setDesktopLyricsTranslationFontSize,
          ),
        ),
        _desktopLyricsPreview(context, settings),
      ],
      SettingsSection.download => [
        _tile(
          context,
          icon: Icons.folder,
          title: '下载路径',
          trailing: SizedBox(
            width: 168,
            child: Text(
              settings?.downloadPath == null || settings!.downloadPath.isEmpty
                  ? '默认'
                  : AndroidStorage.displayPath(settings.downloadPath),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
            ),
          ),
          onTap: () => _pickDownloadPath(context, ref, settings),
        ),
        _tile(
          context,
          icon: Icons.download,
          title: '下载音质',
          trailing: Text(
            qualityDisplayLabel(settings?.downloadQuality ?? '320k'),
          ),
          onTap: () => _pickQuality(context, ref, settings, isOnline: false),
        ),
        _tile(
          context,
          icon: Icons.tune_rounded,
          title: '每次下载是否询问细节',
          trailing: DropdownButtonHideUnderline(
            child: DropdownButton<bool>(
              value: settings?.askDownloadDetails ?? true,
              isDense: true,
              alignment: AlignmentDirectional.centerEnd,
              items: const [
                DropdownMenuItem(value: true, child: Text('询问')),
                DropdownMenuItem(value: false, child: Text('不询问')),
              ],
              onChanged: (value) {
                if (value != null) notifier.setAskDownloadDetails(value);
              },
            ),
          ),
        ),
        _switchTile(
          context,
          icon: Icons.lyrics,
          title: '同时下载歌词',
          value: settings?.downloadLyrics ?? true,
          onChanged: (v) => notifier.setDownloadLyrics(v),
        ),
        _switchTile(
          context,
          icon: Icons.library_music_outlined,
          title: '下载时写入元数据',
          subtitle: '将封面、歌词、标题等标签写入音频文件',
          value: settings?.downloadWriteMetadata ?? true,
          onChanged: (v) => notifier.setDownloadWriteMetadata(v),
        ),
      ],
      SettingsSection.backup => [
        ListTile(
          title: const Text('备份内容'),
          subtitle: const Text(
            '歌单、收藏、本地曲库（扫描文件夹与歌曲信息）、'
            '插件与用户变量、主题、全部设置与歌词关联',
          ),
        ),
        _tile(
          context,
          icon: Icons.file_upload_outlined,
          title: _exportingBackup ? '正在导出…' : '导出备份',
          trailing: const Text(''),
          onTap: _exportingBackup ? null : _exportBackup,
        ),
        _tile(
          context,
          icon: Icons.file_download_outlined,
          title: _importingBackup ? '正在导入…' : '导入备份',
          trailing: const Text(''),
          onTap: _importingBackup ? null : _importBackup,
        ),
      ],
      SettingsSection.other => [
        _tile(
          context,
          icon: Icons.query_stats,
          title: '听歌统计',
          trailing: const Text(''),
          onTap: () => context.push('/settings/statistics'),
        ),
        _batteryOptimizationTile(context),
      ],
      SettingsSection.feedback => const [],
    };
  }

  /// 播放失败策略弹层入口：重试次数、换源次数与策略优先级集中在弹层内编辑。
  Future<void> _showPlaybackFailurePolicy(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const _PlaybackFailurePolicySheet(),
    );
  }

  /// 根页卡片流：按「个性化 / 音乐 / 应用」三类目组织（对齐参考实现
  /// CurrentMusicX SettingsScreen 的分组方式），每个类目是一张常显卡片：
  /// 组头只作分组标题（不可折叠、无箭头），设置项直接渲染。设置项本体
  /// （_sectionTiles 提供的内容）完全沿用，只重排分类与外层容器，不改任
  /// 何设置项。
  List<Widget> _rootCards(
    BuildContext context, {
    required AppSettings? settings,
    required SettingsNotifier notifier,
    required AuthState auth,
    required AsyncValue<bool> dynamicColorSupported,
  }) {
    // 账号置顶：不归入三类目，单独一张无组头卡片。
    final account = <Widget>[
      _entryRow(
        context,
        title: '账号',
        subtitle: auth.isLoggedIn ? auth.user!.nickname : '登录、注册与账号安全',
        route: '/account?from=settings',
      ),
    ];

    // 个性化：外观、布局、歌词（入口型，进独立页面）。
    final personalization = <Widget>[
      _entryRow(
        context,
        title: '外观',
        subtitle: '主题、颜色、字体、壁纸与封面样式',
        route: '/settings/appearance',
      ),
      _entryRow(
        context,
        title: '布局',
        subtitle: '顶栏与侧边栏布局、自定义底栏、首页模块',
        route: '/settings/layout',
      ),
      _entryRow(
        context,
        title: '歌词',
        subtitle: '翻译、罗马音、逐字动效、蓝牙歌词与桌面歌词',
        route: '/settings/lyrics',
      ),
    ];

    // 音乐：插件管理、播放、下载（入口型，进独立页面）。
    final music = <Widget>[
      _entryRow(
        context,
        title: '插件管理',
        subtitle: '安装、启用与管理音乐插件',
        route: '/settings/plugins',
      ),
      _entryRow(
        context,
        title: '播放',
        subtitle: '音质、音量调节、并发数、失败策略与浮窗',
        route: '/settings/playback',
      ),
      _entryRow(
        context,
        title: '下载',
        subtitle: '下载路径、下载音质与歌词、元数据写入',
        route: '/settings/download',
      ),
    ];

    // 应用：储存、备份、日志、问题反馈、支持开发者、关于、其他。
    final app = <Widget>[
      _entryRow(
        context,
        title: '储存',
        subtitle: '查看并清理封面、播放缓存与临时文件',
        route: '/settings/storage',
      ),
      _entryRow(
        context,
        title: '备份',
        subtitle: '导出或导入歌单、收藏、本地曲库、插件与设置',
        route: '/settings/backup',
      ),
      _entryRow(
        context,
        title: '日志',
        subtitle: '日志保存、筛选与导出',
        route: '/settings/logs',
      ),
      _entryRow(
        context,
        title: '问题反馈',
        subtitle: '提交问题、建议并查看处理进度',
        route: '/settings/feedback',
      ),
      // 「其他」紧跟在问题反馈下面（低频杂项收到靠后位置）。
      _entryRow(
        context,
        title: '其他',
        subtitle: '听歌统计与后台播放保活',
        route: '/settings/other',
      ),
      _entryRow(
        context,
        title: '支持开发者',
        subtitle: '查看赞助说明与收款码',
        route: '/settings/sponsor',
      ),
      _entryRow(
        context,
        title: '关于',
        subtitle: '版本、项目仓库、创作者与开源许可',
        route: '/settings/about',
      ),
    ];

    return [
      _flatCard(context, children: account),
      _categoryCard(
        context,
        category: _SettingsCategory.personalization,
        children: personalization,
      ),
      _categoryCard(
        context,
        category: _SettingsCategory.music,
        children: music,
      ),
      _categoryCard(context, category: _SettingsCategory.app, children: app),
    ];
  }

  /// 无组头的独立卡片（账号置顶行用）：底色与圆角与类目卡片一致。
  Widget _flatCard(BuildContext context, {required List<Widget> children}) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      child: Material(
        color: xyTranslucentCardColor(context) ?? scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _withDivider(context, children),
        ),
      ),
    );
  }

  /// 类目卡片：组头只作分组标题，设置项常显（不折叠、不可点击）。
  Widget _categoryCard(
    BuildContext context, {
    required _SettingsCategory category,
    required List<Widget> children,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      child: Material(
        color: xyTranslucentCardColor(context) ?? scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Icon(
                      category.icon,
                      size: 17,
                      color: scheme.primary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      category.label,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Divider(
              height: 1,
              thickness: .6,
              color: scheme.outlineVariant,
            ),
            ..._withDivider(context, children),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }

  /// 组内相邻项之间插细分隔线（左右内缩 16）。
  List<Widget> _withDivider(BuildContext context, List<Widget> children) {
    final color = Theme.of(context).colorScheme.outlineVariant;
    final out = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        out.add(
          Divider(
            height: 1,
            thickness: .6,
            color: color,
            indent: 16,
            endIndent: 16,
          ),
        );
      }
      out.add(children[i]);
    }
    return out;
  }

  /// 组内入口行：整行可点、右侧箭头，不再另起一张卡片（底色与圆角由
  /// 类目卡片统一提供）。
  Widget _entryRow(
    BuildContext context, {
    required String title,
    required String subtitle,
    required String route,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Builder(
      builder: (rowContext) => InkWell(
        onTap: () => _openSettingsRoute(rowContext, route),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 11, 14, 11),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded, size: 20, color: scheme.outline),
            ],
          ),
        ),
      ),
    );
  }

  /// 设置项跳转：先把被点击行的屏幕矩形登记为「页面展开」转场起点，
  /// 再 push。展开动画本体在路由层（routes.dart 的 _settingsExpandPage），
  /// 设置子页面只用这一种转场，不受全局「页面切换动画」设置影响。
  /// 展开主体是下一页内容本身，这里只需登记矩形与圆角，不再登记卡片底色。
  void _openSettingsRoute(BuildContext rowContext, String route) {
    SettingsExpandOriginRegistry.capture(rowContext);
    context.push(route);
  }

  List<Widget> _searchResultTiles(BuildContext context) {
    final results = searchSettings(_query);
    if (results.isEmpty) {
      return const [
        SizedBox(height: 240, child: Center(child: Text('没有找到相关设置'))),
      ];
    }
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 2, 20, 6),
        child: Text(
          '找到 ${results.length} 项，按设置层级排列',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      for (final entry in results) _settingsSearchTile(context, entry),
    ];
  }

  Widget _settingsSearchTile(BuildContext context, SettingsSearchEntry entry) {
    final scheme = Theme.of(context).colorScheme;
    return Builder(
      builder: (tileContext) => ListTile(
        minTileHeight: 64,
        leading: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: scheme.secondaryContainer.withValues(alpha: .66),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(entry.icon, size: 21, color: scheme.onSecondaryContainer),
        ),
        title: Text(
          entry.title,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          entry.level == 1
              ? (entry.note == null ? '一级分类' : '一级分类 · ${entry.note}')
              : (entry.note == null
                    ? entry.path.join(' › ')
                    : '${entry.path.join(' › ')} · ${entry.note}'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                _levelLabel(entry.level),
                style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(width: 5),
            Icon(Icons.chevron_right_rounded, size: 19, color: scheme.outline),
          ],
        ),
        onTap: () => _openSettingsRoute(tileContext, entry.route),
      ),
    );
  }

  String _levelLabel(int level) => switch (level) {
    1 => '一级',
    2 => '二级',
    3 => '三级',
    _ => '$level 级',
  };

  String get _pageTitle => switch (section) {
    SettingsSection.root => '设置',
    SettingsSection.account => '账号',
    SettingsSection.appearance => '外观',
    SettingsSection.layout => '布局',
    SettingsSection.sidebarLayout => '侧边栏布局',
    SettingsSection.bottomBar => '自定义底栏',
    SettingsSection.playback => '播放',
    SettingsSection.volume => '音量调节设置',
    SettingsSection.playbackDetail => '播放详情页歌词',
    SettingsSection.lyrics => '歌词',
    SettingsSection.desktopLyrics => '桌面歌词',
    SettingsSection.download => '下载',
    SettingsSection.backup => '备份与恢复',
    SettingsSection.other => '其他',
    SettingsSection.feedback => '问题反馈',
  };

  Widget _categoryTile(
    BuildContext context, {
    required String title,
    required String subtitle,
    required String route,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Builder(
      builder: (tileContext) => ListTile(
        minTileHeight: 64,
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Icon(Icons.chevron_right, color: scheme.outline),
        onTap: () => _openSettingsRoute(tileContext, route),
      ),
    );
  }

  /// 后台播放保活引导（仅未豁免电池优化时展示）。
  ///
  /// 华为/荣耀等国内 ROM 的省电策略会在锁屏或切后台后限制甚至强杀正在
  /// 播放的前台服务，导致音乐中断、进程被杀。检测到尚未豁免时展示入口，
  /// 点击弹出系统路径说明并可直接拉起授权弹窗。
  Widget _batteryOptimizationTile(BuildContext context) {
    final ignored = ref.watch(batteryOptimizationIgnoredProvider);
    // 加载中或已豁免（含非 Android）时不展示引导。
    if (ignored.valueOrNull != false) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      minTileHeight: 64,
      leading: Icon(Icons.battery_saver_outlined, color: scheme.primary),
      title: const Text(
        '后台播放保活',
        style: TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: const Text(
        '华为/荣耀等机型的省电策略可能中断后台播放，建议加入白名单',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Icon(Icons.chevron_right, color: scheme.outline),
      onTap: () => _showBatteryOptimizationGuide(context),
    );
  }

  /// 后台保活引导弹窗：给出华为/荣耀的具体设置路径，并可直接拉起系统
  /// 的「忽略电池优化」授权弹窗；返回后刷新状态，已豁免则入口自动隐藏。
  Future<void> _showBatteryOptimizationGuide(BuildContext context) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('开启后台播放保活'),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('系统默认的省电策略会在锁屏或切到后台时限制本应用，可能导致音乐中断甚至进程被杀。建议关闭对本应用的电池优化。'),
              SizedBox(height: 12),
              Text(
                '华为 / 荣耀（EMUI · HarmonyOS）：',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              SizedBox(height: 4),
              Text(
                '设置 → 电池 → 启动管理 → 找到「XY Music」→ 关闭「自动管理」→ '
                '手动管理中勾选「允许自启动」「允许关联启动」「允许后台活动」。',
              ),
              SizedBox(height: 12),
              Text('也可点击下方「立即设置」，在系统弹窗中选择「允许」。'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('立即设置'),
          ),
        ],
      ),
    );
    if (go != true) return;
    await requestIgnoreBatteryOptimizations();
    // 用户可能已在系统弹窗中授权：重新探测，已豁免时入口自动隐藏。
    ref.invalidate(batteryOptimizationIgnoredProvider);
  }

  /// 桌面歌词纵向位置（百分制）：0% = 屏幕最顶端、50% = 屏幕正中、
  /// 100% = 屏幕最底端。滑块每 10% 一个刻度（divisions: 10），与播放页
  /// 歌词字号滑块的刻度样式一致。
  Widget _desktopLyricsPositionTile(
    BuildContext context,
    AppSettings? settings,
    SettingsNotifier notifier,
  ) {
    final percent = (settings?.desktopLyricsVerticalPercent ?? 90.0).clamp(
      0.0,
      100.0,
    );
    final label = '${percent.round()}%';
    final scheme = Theme.of(context).colorScheme;
    final hintStyle = TextStyle(fontSize: 11, color: scheme.outline);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.vertical_align_center_rounded,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              const Expanded(child: Text('上下位置')),
              Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          Slider(
            value: percent,
            min: 0,
            max: 100,
            divisions: 10,
            label: label,
            onChanged: notifier.setDesktopLyricsVerticalPercent,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('顶部 0%', style: hintStyle),
                Text('居中 50%', style: hintStyle),
                Text('底部 100%', style: hintStyle),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required Widget trailing,
    VoidCallback? onTap,
    TextStyle? titleStyle,
  }) {
    return Builder(
      builder: (tileContext) => ListTile(
        title: Text(title, style: titleStyle),
        trailing: onTap == null
            ? trailing
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  trailing,
                  const SizedBox(width: 4),
                  Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ],
              ),
        // 行的可点行为有两类：进下一级页面（登记展开起点）或弹层；
        // 弹层场景登记的起点不会被消费（登记表自带过期兜底），
        // 不会干扰其它导航。
        onTap: onTap == null
            ? null
            : () {
                SettingsExpandOriginRegistry.capture(tileContext);
                onTap();
              },
      ),
    );
  }

  Widget _switchTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
    String? subtitle,
  }) {
    return SwitchListTile(
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      value: value,
      onChanged: onChanged,
    );
  }

  Widget _dynamicColorTile(
    BuildContext context, {
    required AppSettings? settings,
    required bool supported,
    required bool loading,
    required ValueChanged<bool> onChanged,
  }) {
    final enabled = supported && !loading;
    final subtitle = loading
        ? '正在检测系统版本…'
        : supported
        ? '跟随 Android 12+ 系统壁纸颜色'
        : '当前系统不支持（需要 Android 12 或更高版本）';
    return SwitchListTile(
      title: Text(
        '动态取色',
        style: enabled
            ? null
            : TextStyle(color: Theme.of(context).disabledColor),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          color: enabled
              ? Theme.of(context).colorScheme.onSurfaceVariant
              : Theme.of(context).disabledColor,
        ),
      ),
      value: settings?.dynamicColor ?? false,
      onChanged: enabled ? onChanged : null,
    );
  }

  Widget _themeLabel(AppSettings? s) {
    return Text(switch (s?.themeMode ?? ThemeModePreference.system) {
      ThemeModePreference.system => '跟随系统',
      ThemeModePreference.light => '浅色',
      ThemeModePreference.dark => '深色',
    });
  }

  String _lyricWordEffectLabel(LyricWordEffectMode mode) => switch (mode) {
    LyricWordEffectMode.wordByWord => '逐词播放',
    LyricWordEffectMode.progressive => '渐进填充',
    LyricWordEffectMode.none => '不显示逐字',
  };

  String _lyricDisplayAlignmentLabel(LyricDisplayAlignment alignment) =>
      switch (alignment) {
        LyricDisplayAlignment.left => '靠左',
        LyricDisplayAlignment.center => '居中',
        LyricDisplayAlignment.right => '靠右',
      };

  String _playerDetailBackgroundLabel(PlayerDetailBackgroundMode mode) =>
      switch (mode) {
        PlayerDetailBackgroundMode.coverBlur => '氛围',
        PlayerDetailBackgroundMode.wallpaperBlur => '壁纸模糊',
        PlayerDetailBackgroundMode.flowingLight => '氛围',
        PlayerDetailBackgroundMode.customImage => '自定义图片',
        PlayerDetailBackgroundMode.particle => '氛围',
      };

  String _playerCoverStyleLabel(PlayerCoverStyle style) => switch (style) {
    PlayerCoverStyle.classic => '经典方形',
    PlayerCoverStyle.circle => '圆形旋转',
    PlayerCoverStyle.immersive => '沉浸式',
    PlayerCoverStyle.vinyl => '黑胶唱片',
  };

  String _pageTransitionModeLabel(PageTransitionMode mode) => switch (mode) {
    PageTransitionMode.slide => '平移',
    PageTransitionMode.stack => '层叠',
    PageTransitionMode.fade => '淡入淡出',
  };

  /// 「播放歌曲时」下拉标签：折叠态短标签（short），展开菜单用完整说明。
  String _playSongQueueModeLabel(
    PlaySongQueueMode mode, {
    bool short = false,
  }) => switch (mode) {
    PlaySongQueueMode.wholeList =>
      short ? '整个列表' : '将整个列表加入到播放队列',
    PlaySongQueueMode.singleSong =>
      short ? '仅此歌曲' : '仅将此歌曲加入到播放队列',
  };

  /// 搜索并发数（搜索线程）的下拉文案：0=全部并行，1~5=最多同时 N 个。
  String _searchConcurrencyLabel(int value) => switch (value) {
    0 => '全部并行',
    1 => '串行（1）',
    _ => '$value 个并发',
  };

  Future<void> _setPlayerDetailBackground(
    BuildContext context,
    WidgetRef ref,
    PlayerDetailBackgroundMode mode,
  ) async {
    final settings = ref.read(settingsProvider).valueOrNull;
    final hasWallpaper =
        settings?.customBackgroundPath.trim().isNotEmpty == true;
    final hasDetailImage =
        settings?.playerDetailCustomImagePath.trim().isNotEmpty == true;
    final missingImage = mode == PlayerDetailBackgroundMode.wallpaperBlur
        ? !hasWallpaper
        : mode == PlayerDetailBackgroundMode.customImage && !hasDetailImage;
    if (missingImage) {
      if (context.mounted) {
        XyNotice.show(
          context,
          message: mode == PlayerDetailBackgroundMode.wallpaperBlur
              ? '未设置壁纸，请先在“自定义壁纸”中选择图片'
              : '未设置详情页图片，请先选择详情页自定义图片',
          type: XyNoticeType.warning,
        );
      }
      return;
    }
    await ref
        .read(settingsProvider.notifier)
        .setPlayerDetailBackgroundMode(mode);
  }

  Future<void> _pickPlayerDetailImage(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
      // 插件默认 compressionQuality=30，会在原生层把图片压缩后写入
      // 公共 Pictures 目录——Android 10 分区存储下无写权限直接
      // IOException 权限被拒绝崩溃（vivo V1821A 实测）。传 0 跳过。
      compressionQuality: 0,
    );
    if (picked == null || picked.files.isEmpty) return;
    final file = picked.files.single;
    final bytes = file.bytes;
    final sourcePath = file.path;
    if ((bytes == null || bytes.isEmpty) && sourcePath == null) {
      if (context.mounted) {
        XyNotice.show(
          context,
          message: '无法读取图片，请重新选择',
          type: XyNoticeType.warning,
        );
      }
      return;
    }
    if ((bytes?.length ?? 0) > 20 * 1024 * 1024) {
      if (context.mounted) {
        XyNotice.show(
          context,
          message: '图片不能超过 20 MB',
          type: XyNoticeType.warning,
        );
      }
      return;
    }
    try {
      final dataDir = await ref.read(appDataDirProvider.future);
      final directory = Directory(p.join(dataDir, 'appearance'));
      await directory.create(recursive: true);
      final extension = p.extension(sourcePath ?? file.name).toLowerCase();
      final safeExtension =
          const ['.jpg', '.jpeg', '.png', '.webp', '.gif'].contains(extension)
          ? extension
          : '.jpg';
      final target = File(
        p.join(
          directory.path,
          'player_detail_${DateTime.now().microsecondsSinceEpoch}$safeExtension',
        ),
      );
      if (bytes != null && bytes.isNotEmpty) {
        await target.writeAsBytes(bytes, flush: true);
      } else {
        await File(sourcePath!).copy(target.path);
      }
      if (context.mounted) await precacheImage(FileImage(target), context);
      await ref
          .read(settingsProvider.notifier)
          .setPlayerDetailCustomImagePath(target.path);
      if (context.mounted) {
        XyNotice.show(
          context,
          message: '详情页自定义图片已更新',
          type: XyNoticeType.success,
        );
      }
    } catch (error) {
      if (context.mounted) {
        XyNotice.show(
          context,
          message: '保存详情页图片失败：$error',
          type: XyNoticeType.error,
        );
      }
    }
  }

  Future<void> _setDesktopLyrics(
    BuildContext context,
    WidgetRef ref,
    bool enabled,
  ) async {
    final notifier = ref.read(settingsProvider.notifier);
    if (enabled) {
      // 权限规范：手动开启小窗类功能时才检测并询问跳转授权页（与迷你
      // 播放器浮窗一致）。
      if (!await MiniPlayerOverlayBridge.hasOverlayPermission()) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('请授予悬浮窗权限后再开启桌面歌词')));
          await MiniPlayerOverlayBridge.requestOverlayPermission();
        }
        return;
      }
      final started = await DesktopLyricsBridge.setEnabled(true);
      if (!started) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('桌面歌词启动失败，请重试')));
        }
        return;
      }
    } else {
      await DesktopLyricsBridge.setEnabled(false);
    }
    await notifier.setDesktopLyricsEnabled(enabled);
  }

  /// 迷你播放器浮窗开关：开启前先查悬浮窗权限——未授权则拉起授权页并
  /// 提示（不写入设置），授权后需回到本页重新打开；已授权才写入设置，
  /// 由根节点同步显示浮窗。自动同步链路（进 app）不会拉授权页。
  Future<void> _setMiniPlayerOverlay(
    BuildContext context,
    WidgetRef ref,
    bool enabled,
  ) async {
    if (enabled) {
      if (!await MiniPlayerOverlayBridge.hasOverlayPermission()) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('请授予悬浮窗权限后再开启迷你播放器浮窗')));
          await MiniPlayerOverlayBridge.requestOverlayPermission();
        }
        return;
      }
      final accepted = await MiniPlayerOverlayBridge.setEnabled(true);
      if (!accepted) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('浮窗启动失败，请重试')));
        }
        return;
      }
    } else {
      await MiniPlayerOverlayBridge.setEnabled(false);
    }
    await ref
        .read(settingsProvider.notifier)
        .setMiniPlayerOverlayEnabled(enabled);
  }

  Widget _desktopColorDot(BuildContext context, int value) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: Color(value),
        shape: BoxShape.circle,
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
    );
  }

  Widget _desktopLyricsPreview(BuildContext context, AppSettings? settings) {
    final noBackground = settings?.desktopLyricsNoBackground ?? true;
    final lyricColor = Color(settings?.desktopLyricsLyricColor ?? 0xFFFFFFFF);
    final translationColor = Color(
      settings?.desktopLyricsTranslationColor ?? 0xFFE1E1E6,
    );
    final background = Color(
      settings?.desktopLyricsBackgroundColor ?? 0xFF18181C,
    ).withValues(alpha: settings?.desktopLyricsBackgroundOpacity ?? .85);
    final lyricFontSize = settings?.desktopLyricsLyricFontSize ?? 24;
    final translationFontSize =
        settings?.desktopLyricsTranslationFontSize ?? 12;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '效果预览',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
            decoration: BoxDecoration(
              color: noBackground ? Colors.transparent : background,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            child: Column(
              children: [
                Text(
                  '当前播放歌词',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: lyricColor,
                    fontSize: lyricFontSize,
                    height: 1.3,
                    fontWeight: FontWeight.w800,
                    shadows: const [
                      Shadow(color: Colors.black54, blurRadius: 12),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Translation',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: translationColor,
                    fontSize: translationFontSize,
                    height: 1.25,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _desktopLyricsFontSizeControl({
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
  }) {
    final normalized = value.clamp(min, max).toDouble();
    return SizedBox(
      width: 168,
      child: Row(
        children: [
          SizedBox(
            width: 30,
            child: Text(
              normalized.round().toString(),
              textAlign: TextAlign.center,
            ),
          ),
          Expanded(
            child: Slider(
              value: normalized,
              min: min,
              max: max,
              divisions: (max - min).round(),
              label: normalized.round().toString(),
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  Widget _volumeSlider(AppSettings? s, SettingsNotifier n) {
    return SizedBox(
      width: 120,
      child: Slider(value: s?.volume ?? 1.0, onChanged: (v) => n.setVolume(v)),
    );
  }

  Future<void> _pickThemeMode(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    final cur = s?.themeMode ?? ThemeModePreference.system;
    final choice = await showModalBottomSheet<_Choice>(
      context: context,
      useRootNavigator: true,
      builder: (sheetContext) => _choiceSheet(
        sheetContext,
        const [
          _Choice('跟随系统', ThemeModePreference.system),
          _Choice('浅色', ThemeModePreference.light),
          _Choice('深色', ThemeModePreference.dark),
        ],
        cur,
        labelOf: (v) => switch (v) {
          ThemeModePreference.system => '跟随系统',
          ThemeModePreference.light => '浅色',
          ThemeModePreference.dark => '深色',
          _ => '跟随系统',
        },
      ),
    );
    if (choice != null) {
      await ref
          .read(settingsProvider.notifier)
          .setThemeMode(choice.value as ThemeModePreference);
    }
  }

  Future<void> _pickSidebarPosition(
    BuildContext context,
    WidgetRef ref,
    AppSettings? settings,
  ) async {
    final current = settings?.sidebarPosition ?? SidebarPosition.left;
    final choice = await showModalBottomSheet<SidebarPosition>(
      context: context,
      useRootNavigator: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.align_horizontal_left_rounded),
              title: const Text('左上'),
              trailing: current == SidebarPosition.left
                  ? Icon(
                      Icons.check,
                      color: Theme.of(sheetContext).colorScheme.primary,
                    )
                  : null,
              onTap: () => Navigator.pop(sheetContext, SidebarPosition.left),
            ),
            ListTile(
              leading: const Icon(Icons.align_horizontal_right_rounded),
              title: const Text('右上'),
              trailing: current == SidebarPosition.right
                  ? Icon(
                      Icons.check,
                      color: Theme.of(sheetContext).colorScheme.primary,
                    )
                  : null,
              onTap: () => Navigator.pop(sheetContext, SidebarPosition.right),
            ),
          ],
        ),
      ),
    );
    if (choice != null) {
      await ref.read(settingsProvider.notifier).setSidebarPosition(choice);
    }
  }

  Future<void> _pickAccentColor(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    final cur = s?.accentColor ?? 0xFFEC4141;
    const colors = [
      0xFFEC4141,
      0xFFE64A2E,
      0xFFFF8A00,
      0xFF4CAF50,
      0xFF2196F3,
      0xFF7C4DFF,
      0xFF9C27B0,
      0xFF795548,
      0xFF607D8B,
      0xFF000000,
    ];
    final choice = await showModalBottomSheet<int>(
      context: context,
      // 使用根 Navigator：色板弹窗覆盖悬浮底栏/迷你播放栏，避免被遮挡。
      useRootNavigator: true,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('主题色', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final c in colors)
                  InkWell(
                    onTap: () => Navigator.pop(sheetContext, c),
                    borderRadius: BorderRadius.circular(20),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Color(c),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: c == cur
                              ? Theme.of(sheetContext).colorScheme.primary
                              : Colors.transparent,
                          width: 3,
                        ),
                      ),
                      child: c == cur
                          ? const Icon(
                              Icons.check,
                              color: Colors.white,
                              size: 20,
                            )
                          : null,
                    ),
                  ),
                // 自定义调色入口：未命中预设色时也允许从当前色继续微调。
                InkWell(
                  onTap: () => Navigator.pop(sheetContext, -1),
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: colors.contains(cur)
                            ? Colors.transparent
                            : Theme.of(sheetContext).colorScheme.primary,
                        width: 3,
                      ),
                      gradient: const SweepGradient(
                        colors: [
                          Color(0xFFFF0000),
                          Color(0xFFFFFF00),
                          Color(0xFF00FF00),
                          Color(0xFF00FFFF),
                          Color(0xFF0000FF),
                          Color(0xFFFF00FF),
                          Color(0xFFFF0000),
                        ],
                      ),
                    ),
                    child: const Icon(
                      Icons.colorize_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (choice == -1) {
      // 自定义调色：打开 HSV 调色弹窗，从当前主题色起步。
      if (!context.mounted) return;
      final custom = await showCustomColorPicker(context, initialColor: cur);
      if (custom != null) {
        await ref.read(settingsProvider.notifier).setAccentColor(custom);
      }
      return;
    }
    if (choice != null) {
      await ref.read(settingsProvider.notifier).setAccentColor(choice);
    }
  }

  Future<void> _editCustomBackground(
    BuildContext context,
    WidgetRef ref,
    AppSettings? settings,
  ) async {
    var imagePath = settings?.customBackgroundPath ?? '';
    var blur = settings?.customBackgroundBlur ?? 18.0;
    var fade = settings?.customBackgroundFade ?? 0.0;
    final result = await showModalBottomSheet<_CustomBackgroundResult>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          Future<void> pickImage() async {
            final picked = await FilePicker.platform.pickFiles(
              type: FileType.image,
              withData: true,
              // 同上：禁用插件压缩，避免写公共 Pictures 目录被拒导致闪退。
              compressionQuality: 0,
            );
            if (picked == null || picked.files.isEmpty) return;
            final file = picked.files.single;
            final bytes = file.bytes;
            final sourcePath = file.path;
            if ((bytes == null || bytes.isEmpty) && sourcePath == null) {
              if (context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('无法读取图片，请重新选择')));
              }
              return;
            }
            if ((bytes?.length ?? 0) > 20 * 1024 * 1024) {
              if (context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('图片不能超过 20 MB')));
              }
              return;
            }
            try {
              final dataDir = await ref.read(appDataDirProvider.future);
              final directory = Directory(p.join(dataDir, 'appearance'));
              await directory.create(recursive: true);
              final extension = p
                  .extension(sourcePath ?? file.name)
                  .toLowerCase();
              final safeExtension =
                  const [
                    '.jpg',
                    '.jpeg',
                    '.png',
                    '.webp',
                    '.gif',
                  ].contains(extension)
                  ? extension
                  : '.jpg';
              // 文件名必须每次都变化。若覆盖同一个路径，Flutter 的 ImageProvider
              // 和根节点 ui.Image 都会认为图片没变，用户换图后仍会显示旧缓存。
              final target = File(
                p.join(
                  directory.path,
                  'custom_background_${DateTime.now().microsecondsSinceEpoch}$safeExtension',
                ),
              );
              if (bytes != null && bytes.isNotEmpty) {
                await target.writeAsBytes(bytes, flush: true);
              } else {
                await File(sourcePath!).copy(target.path);
              }
              if (context.mounted) {
                // 全分辨率解码会让一张高像素照片占用上百 MB 内存，
                // 与根节点背景保持一致，按 1440 宽预缓存。
                await precacheImage(
                  ResizeImage(FileImage(target), width: 1440),
                  context,
                );
              }
              if (context.mounted) {
                setSheetState(() => imagePath = target.path);
              }
            } catch (error) {
              if (context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('保存背景图片失败：$error')));
              }
            }
          }

          /// 选择动态壁纸（视频）。落盘后与图片壁纸共用同一个设置项，
          /// 渲染层按扩展名判断该走图片还是视频。
          Future<void> pickVideo() async {
            // 视频固定 withData:false：几十上百 MB 读进内存再写盘，
            // 低端机会被 LMK 直接杀掉。
            final picked = await FilePicker.platform.pickFiles(
              type: FileType.custom,
              allowedExtensions: const [
                'mp4',
                'm4v',
                'mov',
                'webm',
                'mkv',
                '3gp',
              ],
              withData: false,
            );
            if (picked == null || picked.files.isEmpty) return;
            final file = picked.files.single;
            final sourcePath = file.path;
            if (sourcePath == null) {
              if (context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('无法读取视频，请重新选择')));
              }
              return;
            }
            // 壁纸是常驻循环播放，300 MB 封顶：再大的文件光是复制落盘
            // 就要十几秒，硬解缓冲也会把常驻内存顶穿。
            if (file.size > 300 * 1024 * 1024) {
              if (context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('视频不能超过 300 MB')));
              }
              return;
            }
            try {
              final dataDir = await ref.read(appDataDirProvider.future);
              final directory = Directory(p.join(dataDir, 'appearance'));
              await directory.create(recursive: true);
              final extension = p.extension(sourcePath).toLowerCase();
              final safeExtension = const [
                '.mp4',
                '.m4v',
                '.mov',
                '.webm',
                '.mkv',
                '.3gp',
              ].contains(extension)
                  ? extension
                  : '.mp4';
              // 文件名每次都变化，理由同图片：复用旧路径会被当缓存命中。
              final target = File(
                p.join(
                  directory.path,
                  'custom_background_${DateTime.now().microsecondsSinceEpoch}$safeExtension',
                ),
              );
              await File(sourcePath).copy(target.path);
              if (context.mounted) {
                setSheetState(() => imagePath = target.path);
              }
            } catch (error) {
              if (context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('保存背景视频失败：$error')));
              }
            }
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '自定义壁纸',
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '支持图片与动态视频（mp4 / mov / webm 等），仅保存在本机，不会上传到服务器。',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 14),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: SizedBox(
                      height: 170,
                      width: double.infinity,
                      child: XyAppBackground(
                        imagePath: imagePath,
                        blur: blur,
                        fade: fade,
                        child: Center(
                          child: Text(
                            imagePath.isEmpty ? '尚未选择壁纸' : 'XY Music 壁纸预览',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              shadows: [
                                Shadow(blurRadius: 8, color: Colors.black87),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      const Icon(Icons.blur_on_outlined, size: 20),
                      const SizedBox(width: 8),
                      const Text('模糊度'),
                      const Spacer(),
                      Text('${blur.toStringAsFixed(0)} px'),
                    ],
                  ),
                  Slider(
                    value: blur.clamp(0.0, 40.0),
                    min: 0,
                    max: 40,
                    divisions: 40,
                    label: '${blur.toStringAsFixed(0)} px',
                    onChanged: (value) => setSheetState(() => blur = value),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(Icons.brightness_6_outlined, size: 20),
                      const SizedBox(width: 8),
                      const Text('背景淡化'),
                      const Spacer(),
                      Text('${(fade * 100).toStringAsFixed(0)}%'),
                    ],
                  ),
                  Slider(
                    value: fade.clamp(0.0, 1.0),
                    min: 0,
                    max: 1,
                    divisions: 20,
                    label: '${(fade * 100).toStringAsFixed(0)}%',
                    onChanged: (value) => setSheetState(() => fade = value),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: pickImage,
                        icon: const Icon(Icons.image_outlined),
                        label: const Text('图片'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: pickVideo,
                        icon: const Icon(Icons.movie_outlined),
                        label: const Text('视频'),
                      ),
                      const Spacer(),
                      if (imagePath.isNotEmpty)
                        TextButton(
                          onPressed: () => setSheetState(() => imagePath = ''),
                          child: const Text('恢复默认'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(
                        sheetContext,
                        _CustomBackgroundResult(imagePath, blur, fade),
                      ),
                      child: const Text('应用'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (result == null || !context.mounted) return;
    final notifier = ref.read(settingsProvider.notifier);
    await notifier.setCustomBackgroundPath(result.path);
    await notifier.setCustomBackgroundBlur(result.blur);
    await notifier.setCustomBackgroundFade(result.fade);
  }

  /// 自定义字体面板：选择 .ttf/.otf 立即应用到全局，或恢复系统默认。
  Future<void> _editCustomFont(BuildContext context, WidgetRef ref) async {
    var enabled =
        ref.read(settingsProvider).valueOrNull?.fontFamily.trim().isNotEmpty ==
        true;
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          Future<void> pickFont() async {
            final picked = await FilePicker.platform.pickFiles(
              type: FileType.custom,
              allowedExtensions: const ['ttf', 'otf'],
              withData: true,
              // 字体文件不能被压缩/转码，禁用插件压缩避免拿到损坏数据。
              compressionQuality: 0,
            );
            if (picked == null || picked.files.isEmpty) return;
            final file = picked.files.single;
            final sourcePath = file.path;
            final bytes = file.bytes;
            final extension = p
                .extension(sourcePath ?? file.name)
                .toLowerCase();
            if (!const ['.ttf', '.otf'].contains(extension)) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('仅支持 .ttf / .otf 字体文件')),
                );
              }
              return;
            }
            if ((bytes == null || bytes.isEmpty) && sourcePath == null) {
              if (context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('无法读取字体文件，请重新选择')));
              }
              return;
            }
            if ((bytes?.length ?? 0) > 100 * 1024 * 1024) {
              if (context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('字体文件不能超过 100 MB')));
              }
              return;
            }
            try {
              final target = File(await customFontFilePath());
              await target.parent.create(recursive: true);
              if (bytes != null && bytes.isNotEmpty) {
                await target.writeAsBytes(bytes, flush: true);
              } else {
                await File(sourcePath!).copy(target.path);
              }
              final loaded = await loadCustomFont(target.path);
              if (!loaded) {
                try {
                  await target.delete();
                } catch (_) {}
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('字体文件解析失败，请换一个文件')),
                  );
                }
                return;
              }
              await ref
                  .read(settingsProvider.notifier)
                  .setFontFamily(kCustomFontFamily);
              if (context.mounted) {
                setSheetState(() => enabled = true);
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('已应用自定义字体')));
              }
            } catch (error) {
              if (context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('保存字体失败：$error')));
              }
            }
          }

          Future<void> resetFont() async {
            await ref.read(settingsProvider.notifier).setFontFamily('');
            try {
              final target = File(await customFontFilePath());
              if (await target.exists()) await target.delete();
            } catch (_) {}
            if (context.mounted) {
              setSheetState(() => enabled = false);
            }
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '自定义字体',
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '字体仅保存在本机，不会上传到服务器。支持 .ttf / .otf，'
                    '应用后全局界面文字都会切换。',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      '预览：晴天 阴天 傍晚 车窗外\nABC abc 0123 哆来咪\n正在播放 · 自定义字体',
                      style: TextStyle(
                        fontFamily: enabled ? kCustomFontFamily : null,
                        fontSize: 16,
                        height: 1.6,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: pickFont,
                        icon: const Icon(Icons.upload_file_outlined),
                        label: const Text('选择字体'),
                      ),
                      const Spacer(),
                      if (enabled)
                        TextButton(
                          onPressed: resetFont,
                          child: const Text('恢复默认'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _pickQuality(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s, {
    required bool isOnline,
  }) async {
    final cur = isOnline
        ? s?.onlineDefaultQuality ?? '320k'
        : s?.downloadQuality ?? '320k';
    // 音质档位对齐 MusicFree（低 → 高），完整 12 档；实际能否取到
    // 该档位取决于插件支持，播放时会自动降级。
    const qualityKeys = [
      '96k',
      '128k',
      '192k',
      '320k',
      'flac',
      'flac24bit',
      'hires',
      'vinyl',
      'dolby',
      'atmos',
      'atmos_plus',
      'master',
    ];
    final choice = await showModalBottomSheet<_Choice>(
      context: context,
      useRootNavigator: true,
      builder: (sheetContext) => _choiceSheet(
        sheetContext,
        [
          for (final key in qualityKeys)
            _Choice(qualityDisplayLabel(key), key),
        ],
        cur,
        labelOf: (v) => qualityDisplayLabel(v as String),
      ),
    );
    if (choice != null) {
      final n = ref.read(settingsProvider.notifier);
      if (isOnline) {
        await n.setOnlineDefaultQuality(choice.value as String);
      } else {
        await n.setDownloadQuality(choice.value as String);
      }
    }
  }

  Future<void> _pickDownloadPath(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    final cur = s?.downloadPath ?? '';
    var selectedPath = cur;
    final controller = TextEditingController(
      text: AndroidStorage.displayPath(cur),
    );
    final action = await showModalBottomSheet<Object?>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('下载路径', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              '留空使用默认下载目录',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(ctx).colorScheme.outline,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              onChanged: (value) => selectedPath = value,
              decoration: const InputDecoration(
                labelText: '路径',
                hintText: '例如 /storage/emulated/0/Music',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () async {
                try {
                  final selected = Platform.isAndroid
                      ? await AndroidStorage.pickDirectory()
                      : await FilePicker.platform.getDirectoryPath();
                  if (!ctx.mounted || selected == null) return;
                  selectedPath = selected;
                  final displayPath = AndroidStorage.displayPath(selected);
                  controller.text = displayPath;
                  controller.selection = TextSelection.collapsed(
                    offset: displayPath.length,
                  );
                } catch (error) {
                  if (!ctx.mounted) return;
                  ScaffoldMessenger.of(
                    ctx,
                  ).showSnackBar(SnackBar(content: Text('选择文件夹失败：$error')));
                }
              },
              icon: const Icon(Icons.folder_open_rounded),
              label: const Text('选择文件夹'),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, 'default'),
                  child: const Text('恢复默认'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, selectedPath.trim()),
                  child: const Text('确定'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (action == null) return;
    final path = action == 'default' ? '' : action as String;
    await ref.read(settingsProvider.notifier).setDownloadPath(path);
  }

  Widget _choiceSheet(
    BuildContext context,
    List<_Choice> choices,
    Object? cur, {
    required String Function(dynamic) labelOf,
  }) {
    return SafeArea(
      // 选项较多（如 12 档音质）时支持滚动，避免底部档位被截断。
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final c in choices)
              ListTile(
                title: Text(labelOf(c.value)),
                trailing: c.value == cur
                    ? Icon(
                        Icons.check,
                        color: Theme.of(context).colorScheme.primary,
                      )
                    : null,
                selected: c.value == cur,
                onTap: () => Navigator.pop(context, c),
              ),
          ],
        ),
      ),
    );
  }
}

/// 桌面歌词「歌词样式」统一面板：歌词/翻译/背景三处颜色与背景透明度
/// 集中在一处调整（原先分散的四个设置项收拢于此）。
/// - 顶部实时预览：按当前三色 + 背景透明度渲染歌词示例；
/// - 目标切换（歌词/翻译/背景）后，下方是共用取色体
///   [ColorPickerBody]（色板 + RGB/十六进制），选背景时额外
///   显示背景透明度滑块；
/// - 所有调整即时写入设置并作用于桌面歌词悬浮窗。
class _DesktopLyricsStyleSheet extends ConsumerStatefulWidget {
  const _DesktopLyricsStyleSheet();

  @override
  ConsumerState<_DesktopLyricsStyleSheet> createState() =>
      _DesktopLyricsStyleSheetState();
}

class _DesktopLyricsStyleSheetState
    extends ConsumerState<_DesktopLyricsStyleSheet> {
  /// 当前取色目标：0=歌词 1=翻译 2=背景。
  int _target = 0;
  static const _targets = ['歌词', '翻译', '背景'];

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider).valueOrNull;
    if (settings == null) {
      return const SizedBox(height: 120);
    }
    final notifier = ref.read(settingsProvider.notifier);
    final lyricColor = settings.desktopLyricsLyricColor;
    final translationColor = settings.desktopLyricsTranslationColor;
    final backgroundColor = settings.desktopLyricsBackgroundColor;
    final opacity = settings.desktopLyricsBackgroundOpacity;
    final currentColor = switch (_target) {
      0 => lyricColor,
      1 => translationColor,
      _ => backgroundColor,
    };
    // 居中弹窗形式：底部弹层会被十六进制输入的软键盘遮住下半部分，
    // Dialog + viewInsets 底部避让让键盘弹出时整体上移不遮挡。
    return Dialog(
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom * 0.6,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.72,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '歌词样式',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // 实时预览：三色 + 背景透明度共同渲染，调整即时可见。
              Container(
                height: 92,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: Color(backgroundColor).withValues(alpha: opacity),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.white12),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            '示例已播放歌词',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Color(lyricColor),
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        const Text(
                          '03:21',
                          style: TextStyle(
                              color: Colors.white38, fontSize: 11),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '示例未播放歌词 · 翻译行',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Color(translationColor),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              SegmentedButton<int>(
                segments: [
                  for (var i = 0; i < _targets.length; i++)
                    ButtonSegment(value: i, label: Text(_targets[i])),
                ],
                selected: {_target},
                showSelectedIcon: false,
                onSelectionChanged: (selection) =>
                    setState(() => _target = selection.first),
              ),
              const SizedBox(height: 14),
              ColorPickerBody(
                // initial 变化时内部 didUpdateWidget 自动重置。
                initial: currentColor,
                onChanged: (value) {
                  switch (_target) {
                    case 0:
                      notifier.setDesktopLyricsLyricColor(value);
                    case 1:
                      notifier.setDesktopLyricsTranslationColor(value);
                    default:
                      notifier.setDesktopLyricsBackgroundColor(value);
                  }
                },
              ),
              // 背景透明度只在「背景」目标下显示（背景颜色面板内调节）。
              if (_target == 2) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    const SizedBox(
                      width: 76,
                      child: Text('背景透明度'),
                    ),
                    Expanded(
                      child: Slider(
                        value: opacity,
                        min: .1,
                        max: 1,
                        divisions: 18,
                        label: '${(opacity * 100).round()}%',
                        onChanged: (value) => notifier
                            .setDesktopLyricsBackgroundOpacity(value),
                      ),
                    ),
                    SizedBox(
                      width: 40,
                      child: Text('${(opacity * 100).round()}%'),
                    ),
                  ],
                ),
              ],
            ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// 首页模块显隐面板：猜你想听固定展示，其余模块按开关动态显隐。
class _HomeModulesSheet extends ConsumerWidget {
  const _HomeModulesSheet();

  static const _moduleMeta = <String, (IconData, String)>{
    kHomeModuleNowPlaying: (Icons.play_circle_outline, '正在播放'),
    kHomeModuleHotComment: (Icons.forum_outlined, '热评推荐'),
    kHomeModuleStatistics: (Icons.insights_outlined, '听歌统计'),
    kHomeModuleLeaderboard: (Icons.leaderboard_outlined, '听歌排行榜'),
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider).valueOrNull;
    final enabled = settings?.homeModules ?? kDefaultHomeModules;
    return ListView(
      shrinkWrap: true,
      // 面板挂在根 Navigator 上覆盖整个屏幕（含悬浮底栏），
      // 底部仅需让出系统安全区。
      padding: EdgeInsets.fromLTRB(
        8,
        0,
        8,
        MediaQuery.paddingOf(context).bottom + 16,
      ),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            '首页模块',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        for (final entry in _moduleMeta.entries)
          SwitchListTile(
            secondary: Icon(entry.value.$1),
            title: Text(entry.value.$2),
            value: enabled.contains(entry.key),
            onChanged: (value) => ref
                .read(settingsProvider.notifier)
                .setHomeModuleEnabled(entry.key, value),
          ),
      ],
    );
  }
}

/// 播放失败策略编辑器：优先重试次数、最大换源尝试次数与可拖动排序的
/// 策略优先级（降低音质 → 换源播放 → 跳下一首 → 暂停播放，按顺序
/// 依次尝试）。
class _PlaybackFailurePolicyEditor extends StatelessWidget {
  const _PlaybackFailurePolicyEditor({
    required this.settings,
    required this.notifier,
  });

  final AppSettings settings;
  final SettingsNotifier notifier;

  static const _stepLabels = <PlaybackFailureStep, String>{
    PlaybackFailureStep.lowerQuality: '降低音质',
    PlaybackFailureStep.switchSource: '换源播放',
    PlaybackFailureStep.playNext: '跳下一首',
    PlaybackFailureStep.pause: '暂停播放',
  };
  static const _stepSubtitles = <PlaybackFailureStep, String>{
    PlaybackFailureStep.lowerQuality: '同一音源逐档降低音质重新解析（如 flac → 320k）',
    PlaybackFailureStep.switchSource: '在其他已启用音源中搜索同名歌曲自动替换',
    PlaybackFailureStep.playNext: '切换到队列中的下一首歌曲',
    PlaybackFailureStep.pause: '停止播放并提示错误信息',
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final priority = settings.playbackFailurePriority;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _countTile(
          context,
          icon: Icons.replay_rounded,
          title: '优先重试次数',
          subtitle: '失败后先用原音源重试当前歌曲，应对偶发网络抖动',
          value: settings.playbackRetryCount,
          onChanged: (value) => unawaited(
            notifier.setPlaybackFailurePolicy(retryCount: value),
          ),
        ),
        _countTile(
          context,
          icon: Icons.swap_horiz_rounded,
          title: '最大换源尝试次数',
          subtitle: '重试仍失败时自动换到其他音源的同名歌曲',
          value: settings.playbackSwitchSourceCount,
          onChanged: (value) => unawaited(
            notifier.setPlaybackFailurePolicy(switchSourceCount: value),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            '播放失败策略优先级',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: scheme.primary,
            ),
          ),
        ),
        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          itemCount: priority.length,
          onReorderItem: (oldIndex, newIndex) {
            final next = [...priority];
            final item = next.removeAt(oldIndex);
            next.insert(newIndex, item);
            unawaited(
              notifier.setPlaybackFailurePolicy(priority: next),
            );
          },
          itemBuilder: (context, index) {
            final step = priority[index];
            return ListTile(
              key: ValueKey('playback-failure-step-${step.name}'),
              leading: Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.primaryContainer,
                ),
                child: Text(
                  '${index + 1}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
              ),
              title: Text(_stepLabels[step] ?? step.name),
              subtitle: Text(
                _stepSubtitles[step] ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: ReorderableDragStartListener(
                index: index,
                child: const Padding(
                  padding: EdgeInsets.all(10),
                  child: Icon(Icons.drag_handle_rounded),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _countTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required int value,
    required ValueChanged<int> onChanged,
  }) {
    return ListTile(
      title: Text(title),
      subtitle: Text(
        subtitle,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _CountButton(
            icon: Icons.remove_rounded,
            onTap: value > 0 ? () => onChanged(value - 1) : null,
          ),
          SizedBox(
            width: 26,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          _CountButton(
            icon: Icons.add_rounded,
            onTap: value < 5 ? () => onChanged(value + 1) : null,
          ),
        ],
      ),
    );
  }
}

/// 播放失败策略弹层：宿主设置页只保留一个入口块，编辑内容集中在此。
class _PlaybackFailurePolicySheet extends ConsumerWidget {
  const _PlaybackFailurePolicySheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings =
        ref.watch(settingsProvider).valueOrNull ?? const AppSettings();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text(
                '播放失败策略',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                child: _PlaybackFailurePolicyEditor(
                  settings: settings,
                  notifier: ref.read(settingsProvider.notifier),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 数字调节按钮（优先重试次数/换源次数用）。
class _CountButton extends StatelessWidget {
  const _CountButton({required this.icon, this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Container(
        width: 34,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: onTap == null ? null : scheme.primaryContainer,
        ),
        child: Icon(
          icon,
          size: 18,
          color: onTap == null ? scheme.outlineVariant : scheme.onPrimaryContainer,
        ),
      ),
    );
  }
}

class _SidebarLayoutEditor extends StatelessWidget {
  const _SidebarLayoutEditor({required this.settings, required this.notifier});

  final AppSettings settings;
  final SettingsNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final order = normalizeSidebarItemOrder(
      settings.sidebarItemOrder,
    ).where((id) => id != kSidebarSettings && id != kSidebarDownloads).toList();
    final hidden = settings.sidebarHiddenItems.toSet();
    return Column(
      children: [
        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          itemCount: order.length,
          onReorderItem: (oldIndex, newIndex) {
            final next = [...order];
            final item = next.removeAt(oldIndex);
            next.insert(newIndex, item);
            unawaited(
              notifier.setSidebarItemOrder([...next, kSidebarSettings]),
            );
          },
          itemBuilder: (context, index) {
            final id = order[index];
            return ListTile(
              key: ValueKey('sidebar-layout-$id'),
              leading: Icon(_sidebarIcon(id)),
              title: Text(_sidebarLabel(id)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Switch(
                    value: !hidden.contains(id),
                    onChanged: (value) =>
                        unawaited(notifier.setSidebarItemVisible(id, value)),
                  ),
                  ReorderableDragStartListener(
                    index: index,
                    child: const Padding(
                      padding: EdgeInsets.all(10),
                      child: Icon(Icons.drag_handle_rounded),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        ListTile(
          key: const ValueKey('sidebar-layout-downloads-fixed'),
          leading: const Icon(Icons.checklist_rounded),
          title: const Text('任务管理'),
          subtitle: const Text('固定在侧边栏底部'),
          trailing: Switch(
            value: !hidden.contains(kSidebarDownloads),
            onChanged: (value) => unawaited(
              notifier.setSidebarItemVisible(kSidebarDownloads, value),
            ),
          ),
        ),
        ListTile(
          key: const ValueKey('sidebar-layout-settings-fixed'),
          leading: const Icon(Icons.settings_outlined),
          title: const Text('设置'),
          subtitle: const Text('固定在侧边栏底部'),
          trailing: Switch(
            value: !hidden.contains(kSidebarSettings),
            onChanged: (value) => unawaited(
              notifier.setSidebarItemVisible(kSidebarSettings, value),
            ),
          ),
        ),
      ],
    );
  }
}

/// 自定义底栏编辑器：挑选 2-5 个目的地并拖动排序。
/// 底栏默认关闭；选满 2 项后自动开启（「完成自定义设置后打开」）。
class _BottomBarLayoutEditor extends StatelessWidget {
  const _BottomBarLayoutEditor({required this.settings, required this.notifier});

  final AppSettings settings;
  final SettingsNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = settings.bottomBarItemIds;
    final selectedSet = selected.toSet();
    final candidates = normalizeSidebarItemOrder(settings.sidebarItemOrder)
        .where((id) => !selectedSet.contains(id))
        .toList();
    final atLeastMin = selected.length >= 2;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: const Icon(Icons.space_dashboard_outlined),
          title: const Text('启用底栏'),
          subtitle: Text(
            atLeastMin
                ? '底部悬浮导航栏，最多 $kBottomBarItemLimit 个项目'
                : '至少选择 2 个项目后自动开启',
          ),
          trailing: Switch(
            value: settings.bottomBarEnabled && atLeastMin,
            onChanged: atLeastMin
                ? (value) => unawaited(notifier.setBottomBarEnabled(value))
                : null,
          ),
        ),
        ListTile(
          leading: const Icon(Icons.label_outline_rounded),
          title: const Text('显示底栏文字'),
          subtitle: const Text('关闭后仅显示图标（紧凑模式）'),
          trailing: Switch(
            value: settings.bottomBarShowLabels,
            onChanged: settings.bottomBarEnabled && atLeastMin
                ? (value) =>
                      unawaited(notifier.setBottomBarShowLabels(value))
                : null,
          ),
        ),
        if (selected.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
            child: Text(
              '已选项目（拖动排序，关闭移除）',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: selected.length,
            onReorderItem: (oldIndex, newIndex) {
              final next = [...selected];
              final item = next.removeAt(oldIndex);
              next.insert(newIndex, item);
              unawaited(notifier.setBottomBarItems(next));
            },
            itemBuilder: (context, index) {
              final id = selected[index];
              return ListTile(
                key: ValueKey('bottom-bar-$id'),
                leading: Icon(_sidebarIcon(id)),
                title: Text(_sidebarLabel(id)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Switch(
                      value: true,
                      onChanged: (_) => unawaited(
                        notifier.setBottomBarItems(
                          selected.where((e) => e != id).toList(),
                        ),
                      ),
                    ),
                    ReorderableDragStartListener(
                      index: index,
                      child: const Padding(
                        padding: EdgeInsets.all(10),
                        child: Icon(Icons.drag_handle_rounded),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
          child: Text(
            selected.length >= kBottomBarItemLimit
                ? '已达 $kBottomBarItemLimit 个上限'
                : '可添加的项目',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ),
        for (final id in candidates)
          ListTile(
            dense: true,
            leading: Icon(_sidebarIcon(id)),
            title: Text(_sidebarLabel(id)),
            trailing: Switch(
              value: false,
              onChanged: selected.length >= kBottomBarItemLimit
                  ? null
                  : (_) => unawaited(
                      notifier.setBottomBarItems([...selected, id]),
                    ),
            ),
          ),
      ],
    );
  }
}

String _sidebarLabel(String id) => switch (id) {
  kSidebarHome => '首页',
  kSidebarExplore => '探索',
  kSidebarMusicLibrary => '音乐库',
  kSidebarPlugins => '插件管理',
  kSidebarAccount => '账号',
  kSidebarRecognize => '听歌识曲',
  kSidebarDownloads => '任务管理',
  kSidebarSettings => '设置',
  _ => id,
};

IconData _sidebarIcon(String id) => switch (id) {
  kSidebarHome => Icons.home_outlined,
  kSidebarExplore => Icons.explore_outlined,
  kSidebarMusicLibrary => Icons.library_music_outlined,
  kSidebarPlugins => Icons.extension_outlined,
  kSidebarAccount => Icons.account_circle_outlined,
  kSidebarRecognize => Icons.mic_none_rounded,
  kSidebarDownloads => Icons.checklist_rounded,
  kSidebarSettings => Icons.settings_outlined,
  _ => Icons.circle_outlined,
};

class _Choice {
  final String label;
  final dynamic value;
  const _Choice(this.label, this.value);
}

class _CustomBackgroundResult {
  const _CustomBackgroundResult(this.path, this.blur, this.fade);

  final String path;
  final double blur;
  final double fade;
}
