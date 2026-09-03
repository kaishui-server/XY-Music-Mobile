import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../../src/core/settings.dart';
import '../../src/player/android_storage.dart';
import '../../src/core/platform_capabilities.dart';
import '../../src/core/db_path.dart';
import '../../src/auth/auth_provider.dart';
import '../../src/navigation/sidebar_controller.dart';
import '../../src/player/desktop_lyrics.dart';
import '../../src/ui/xy_surface.dart';
import '../../src/widgets/top_notice.dart';

enum SettingsSection {
  root,
  account,
  appearance,
  layout,
  playback,
  playbackDetail,
  lyrics,
  desktopLyrics,
  library,
  download,
  other,
  logsDebug,
  feedback,
}

class SettingsSearchEntry {
  const SettingsSearchEntry({
    required this.title,
    required this.path,
    required this.route,
    required this.icon,
    this.keywords = '',
  });

  final String title;
  final List<String> path;
  final String route;
  final IconData icon;
  final String keywords;

  int get level => path.length;
}

const settingsSearchEntries = <SettingsSearchEntry>[
  SettingsSearchEntry(
    title: '账号',
    path: ['账号'],
    route: '/account?from=settings',
    icon: Icons.manage_accounts_outlined,
    keywords: '登录 注册 账号安全 退出',
  ),
  SettingsSearchEntry(
    title: '外观',
    path: ['外观'],
    route: '/settings/appearance',
    icon: Icons.palette_outlined,
    keywords: '主题 模式 颜色 深色 浅色 背景 图片 模糊',
  ),
  SettingsSearchEntry(
    title: '播放',
    path: ['播放'],
    route: '/settings/playback',
    icon: Icons.play_circle_outline_rounded,
    keywords: '音量 音质 屏幕常亮',
  ),
  SettingsSearchEntry(
    title: '布局',
    path: ['布局'],
    route: '/settings/layout',
    icon: Icons.view_quilt_outlined,
    keywords: '顶栏 侧边栏 位置 左上 右上',
  ),
  SettingsSearchEntry(
    title: '歌词',
    path: ['歌词'],
    route: '/settings/playback-detail',
    icon: Icons.queue_music_outlined,
    keywords: '歌词 播放详情 封面 歌词显示',
  ),
  SettingsSearchEntry(
    title: '插件管理',
    path: ['插件管理'],
    route: '/settings/plugins',
    icon: Icons.extension_outlined,
    keywords: '插件 安装 启用 卸载 更新',
  ),
  SettingsSearchEntry(
    title: '音乐库',
    path: ['音乐库'],
    route: '/settings/library',
    icon: Icons.library_music_outlined,
    keywords: '本地 扫描 文件夹 远程 WebDAV',
  ),
  SettingsSearchEntry(
    title: '下载',
    path: ['下载'],
    route: '/settings/download',
    icon: Icons.download_outlined,
    keywords: '保存 路径 音质 歌词',
  ),
  SettingsSearchEntry(
    title: '每次下载是否询问细节',
    path: ['下载', '每次下载是否询问细节'],
    route: '/settings/download',
    icon: Icons.tune_rounded,
    keywords: '询问 不询问 下载弹窗',
  ),
  SettingsSearchEntry(
    title: '其他',
    path: ['其他'],
    route: '/settings/other',
    icon: Icons.tune_rounded,
    keywords: '统计 关于 版本',
  ),
  SettingsSearchEntry(
    title: '账号与安全',
    path: ['账号', '账号与安全'],
    route: '/account?from=settings',
    icon: Icons.account_circle_outlined,
    keywords: '登录 注册 验证码 退出',
  ),
  SettingsSearchEntry(
    title: '播放详情页歌词',
    path: ['歌词', '播放详情页歌词'],
    route: '/settings/lyrics',
    icon: Icons.lyrics_outlined,
    keywords: '翻译 逐字 动效',
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
    title: '播放详情页背景',
    path: ['外观', '播放详情页背景'],
    route: '/settings/appearance',
    icon: Icons.wallpaper_outlined,
    keywords: '封面模糊 壁纸模糊 流光 自定义图片',
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
    title: '音量',
    path: ['播放', '音量'],
    route: '/settings/playback',
    icon: Icons.volume_up_outlined,
  ),
  SettingsSearchEntry(
    title: '在线默认音质',
    path: ['播放', '在线默认音质'],
    route: '/settings/playback',
    icon: Icons.high_quality_outlined,
    keywords: '128k 192k 320k flac 无损',
  ),
  SettingsSearchEntry(
    title: '显示音质标识',
    path: ['播放', '显示音质标识'],
    route: '/settings/playback',
    icon: Icons.verified_outlined,
  ),
  SettingsSearchEntry(
    title: '保持屏幕常亮',
    path: ['播放', '保持屏幕常亮'],
    route: '/settings/playback',
    icon: Icons.screen_lock_rotation_outlined,
    keywords: '不熄屏',
  ),
  SettingsSearchEntry(
    title: '显示翻译',
    path: ['歌词', '播放详情页歌词', '显示翻译'],
    route: '/settings/lyrics',
    icon: Icons.translate_outlined,
  ),
  SettingsSearchEntry(
    title: '逐字动效',
    path: ['歌词', '播放详情页歌词', '逐字动效'],
    route: '/settings/lyrics',
    icon: Icons.spellcheck_outlined,
    keywords: '逐字歌词 动画',
  ),
  SettingsSearchEntry(
    title: '歌词字号',
    path: ['歌词', '播放详情页歌词', '歌词字号'],
    route: '/settings/lyrics',
    icon: Icons.format_size_outlined,
    keywords: '字体 大小 歌词大小',
  ),
  SettingsSearchEntry(
    title: '桌面歌词',
    path: ['歌词', '桌面歌词'],
    route: '/settings/desktop-lyrics',
    icon: Icons.subtitles_outlined,
    keywords: '悬浮歌词 桌面歌词 浮窗 逐字效果',
  ),
  SettingsSearchEntry(
    title: '扫描文件夹',
    path: ['音乐库', '扫描文件夹'],
    route: '/settings/scan-folders',
    icon: Icons.folder_special_outlined,
    keywords: '添加目录 本地音乐',
  ),
  SettingsSearchEntry(
    title: '远程音乐库',
    path: ['音乐库', '远程音乐库'],
    route: '/settings/remote-library',
    icon: Icons.cloud_outlined,
    keywords: 'NAS 网盘 WebDAV',
  ),
  SettingsSearchEntry(
    title: '扫描格式',
    path: ['音乐库', '扫描格式'],
    route: '/settings/library',
    icon: Icons.audiotrack_outlined,
    keywords: 'flac mp3 wav aac m4a ogg aiff',
  ),
  SettingsSearchEntry(
    title: '排除短音频',
    path: ['音乐库', '排除短音频'],
    route: '/settings/library',
    icon: Icons.timer_outlined,
    keywords: '最短时长 秒',
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
  ),
  SettingsSearchEntry(
    title: '听歌统计',
    path: ['其他', '听歌统计'],
    route: '/settings/statistics',
    icon: Icons.query_stats_outlined,
    keywords: '播放次数 时长 历史',
  ),
  SettingsSearchEntry(
    title: '日志与调试',
    path: ['其他', '日志与调试'],
    route: '/settings/logs-debug',
    icon: Icons.bug_report_outlined,
    keywords: '日志 调试 导出 错误 警告',
  ),
  SettingsSearchEntry(
    title: '日志',
    path: ['其他', '日志与调试', '日志'],
    route: '/settings/logs',
    icon: Icons.description_outlined,
    keywords: '保存条数 错误日志 时间范围 导出',
  ),
  SettingsSearchEntry(
    title: '问题反馈',
    path: ['问题反馈'],
    route: '/settings/feedback',
    icon: Icons.feedback_outlined,
    keywords: '功能建议 提交问题 我的反馈 上传图片 日志',
  ),
  SettingsSearchEntry(
    title: '关于 XY Music',
    path: ['其他', '关于 XY Music'],
    route: '/settings/about',
    icon: Icons.info_outline,
    keywords: '版本 开源 许可',
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
    title: 'WebDAV 音乐库',
    path: ['音乐库', '远程音乐库', 'WebDAV 音乐库'],
    route: '/settings/remote-library',
    icon: Icons.dns_outlined,
    keywords: 'NAS 网盘 服务器',
  ),
  SettingsSearchEntry(
    title: '播放缓存',
    path: ['音乐库', '远程音乐库', '播放缓存'],
    route: '/settings/remote-library',
    icon: Icons.cached_outlined,
    keywords: '清理缓存',
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

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key, this.section = SettingsSection.root});

  final SettingsSection section;

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  SettingsSection get section => widget.section;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider).valueOrNull;
    final notifier = ref.read(settingsProvider.notifier);
    final auth = ref.watch(authProvider);
    final dynamicColorSupported = ref.watch(dynamicColorSupportedProvider);

    final children = switch (section) {
      SettingsSection.root => [
        _categoryTile(
          context,
          icon: Icons.manage_accounts_outlined,
          title: '账号',
          subtitle: auth.isLoggedIn ? auth.user!.nickname : '登录、注册与账号安全',
          route: '/account?from=settings',
        ),
        _categoryTile(
          context,
          icon: Icons.extension_outlined,
          title: '插件管理',
          subtitle: '安装、启用与管理音乐插件',
          route: '/settings/plugins',
        ),
        _categoryTile(
          context,
          icon: Icons.palette_outlined,
          title: '外观',
          subtitle: '主题模式与主题色',
          route: '/settings/appearance',
        ),
        _categoryTile(
          context,
          icon: Icons.view_quilt_outlined,
          title: '布局',
          subtitle: '顶栏位置与侧边栏排序',
          route: '/settings/layout',
        ),
        _categoryTile(
          context,
          icon: Icons.play_circle_outline_rounded,
          title: '播放',
          subtitle: '音量、在线音质与屏幕常亮',
          route: '/settings/playback',
        ),
        _categoryTile(
          context,
          icon: Icons.queue_music_outlined,
          title: '歌词',
          subtitle: '播放详情页中的歌词显示设置',
          route: '/settings/playback-detail',
        ),
        _categoryTile(
          context,
          icon: Icons.library_music_outlined,
          title: '音乐库',
          subtitle: '本地扫描与远程音乐库',
          route: '/settings/library',
        ),
        _categoryTile(
          context,
          icon: Icons.download_outlined,
          title: '下载',
          subtitle: '保存位置、音质与歌词',
          route: '/settings/download',
        ),
        _categoryTile(
          context,
          icon: Icons.tune_rounded,
          title: '其他',
          subtitle: '听歌统计与关于',
          route: '/settings/other',
        ),
        _categoryTile(
          context,
          icon: Icons.feedback_outlined,
          title: '问题反馈',
          subtitle: '提交问题、建议并查看处理进度',
          route: '/settings/feedback',
        ),
      ],
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
        _dynamicColorTile(
          context,
          settings: settings,
          supported: dynamicColorSupported.valueOrNull == true,
          loading: dynamicColorSupported.isLoading,
          onChanged: (value) => notifier.setDynamicColor(value),
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
                  PlayerDetailBackgroundMode.coverBlur,
              isDense: true,
              alignment: AlignmentDirectional.centerEnd,
              items: PlayerDetailBackgroundMode.values
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
      ],
      SettingsSection.playback => [
        _tile(
          context,
          icon: Icons.volume_up,
          title: '音量',
          trailing: _volumeSlider(settings, notifier),
        ),
        _tile(
          context,
          icon: Icons.high_quality,
          title: '在线默认音质',
          trailing: Text(settings?.onlineDefaultQuality ?? '320k'),
          onTap: () => _pickQuality(context, ref, settings, isOnline: true),
        ),
        _tile(
          context,
          icon: Icons.error_outline,
          title: '播放失败后',
          trailing: DropdownButtonHideUnderline(
            child: DropdownButton<PlaybackFailureAction>(
              value:
                  settings?.playbackFailureAction ??
                  PlaybackFailureAction.playNext,
              isDense: true,
              alignment: AlignmentDirectional.centerEnd,
              items: const [
                DropdownMenuItem<PlaybackFailureAction>(
                  value: PlaybackFailureAction.playNext,
                  child: Text('播放下一首'),
                ),
                DropdownMenuItem<PlaybackFailureAction>(
                  value: PlaybackFailureAction.pause,
                  child: Text('暂停播放'),
                ),
              ],
              onChanged: (action) {
                if (action != null) {
                  notifier.setPlaybackFailureAction(action);
                }
              },
            ),
          ),
        ),
        _switchTile(
          context,
          icon: Icons.multitrack_audio_rounded,
          title: '播放其他音频不中断此应用播放',
          value: settings?.playOtherAudioWithoutInterruption ?? false,
          onChanged: (value) =>
              notifier.setPlayOtherAudioWithoutInterruption(value),
        ),
        _switchTile(
          context,
          icon: Icons.verified,
          title: '显示音质标识',
          value: settings?.showQualityBadges ?? true,
          onChanged: (v) => notifier.setShowQualityBadges(v),
        ),
        _switchTile(
          context,
          icon: Icons.screen_lock_rotation,
          title: '保持屏幕常亮',
          value: settings?.keepScreenOn ?? true,
          onChanged: (v) => notifier.setKeepScreenOn(v),
        ),
      ],
      SettingsSection.playbackDetail => [
        _tile(
          context,
          icon: Icons.lyrics_outlined,
          title: '播放详情页歌词',
          trailing: const Text(''),
          onTap: () => context.push('/settings/lyrics'),
        ),
        _tile(
          context,
          icon: Icons.subtitles_outlined,
          title: '桌面歌词',
          trailing: const Text(''),
          onTap: () => context.push('/settings/desktop-lyrics'),
        ),
      ],
      SettingsSection.lyrics => [
        _switchTile(
          context,
          icon: Icons.translate,
          title: '显示翻译',
          value: settings?.showLyricsTranslation ?? true,
          onChanged: (v) => notifier.setShowLyricsTranslation(v),
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
          title: '歌词字号',
          trailing: Text(
            (settings?.lyricFontSize ?? 18.0).toStringAsFixed(0),
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          onTap: () => _showLyricFontSizeSheet(context, ref),
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
        _tile(
          context,
          icon: Icons.format_color_text_outlined,
          title: '歌词颜色',
          trailing: _desktopColorDot(
            context,
            settings?.desktopLyricsLyricColor ?? 0xFFFFFFFF,
          ),
          onTap: () => _pickDesktopLyricsColor(
            context,
            ref,
            title: '歌词颜色',
            current: settings?.desktopLyricsLyricColor ?? 0xFFFFFFFF,
            save: notifier.setDesktopLyricsLyricColor,
          ),
        ),
        _tile(
          context,
          icon: Icons.translate_outlined,
          title: '翻译颜色',
          trailing: _desktopColorDot(
            context,
            settings?.desktopLyricsTranslationColor ?? 0xFFE1E1E6,
          ),
          onTap: () => _pickDesktopLyricsColor(
            context,
            ref,
            title: '翻译颜色',
            current: settings?.desktopLyricsTranslationColor ?? 0xFFE1E1E6,
            save: notifier.setDesktopLyricsTranslationColor,
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
            value: settings?.desktopLyricsTranslationFontSize ?? 13,
            min: 10,
            max: 28,
            onChanged: notifier.setDesktopLyricsTranslationFontSize,
          ),
        ),
        _tile(
          context,
          icon: Icons.format_color_fill_outlined,
          title: '背景颜色',
          trailing: _desktopColorDot(
            context,
            settings?.desktopLyricsBackgroundColor ?? 0xFF18181C,
          ),
          onTap: () => _pickDesktopLyricsColor(
            context,
            ref,
            title: '背景颜色',
            current: settings?.desktopLyricsBackgroundColor ?? 0xFF18181C,
            save: notifier.setDesktopLyricsBackgroundColor,
          ),
        ),
        _tile(
          context,
          icon: Icons.opacity_outlined,
          title: '背景透明度',
          trailing: SizedBox(
            width: 145,
            child: Slider(
              value: settings?.desktopLyricsBackgroundOpacity ?? .85,
              min: .1,
              max: 1,
              divisions: 18,
              label:
                  '${(((settings?.desktopLyricsBackgroundOpacity ?? .85) * 100).round())}%',
              onChanged: (value) =>
                  notifier.setDesktopLyricsBackgroundOpacity(value),
            ),
          ),
        ),
        _desktopLyricsPreview(context, settings),
      ],
      SettingsSection.library => [
        _tile(
          context,
          icon: Icons.folder_special,
          title: '扫描文件夹',
          trailing: const Text(''),
          onTap: () => context.push('/settings/scan-folders'),
        ),
        _tile(
          context,
          icon: Icons.cloud_outlined,
          title: '远程音乐库',
          trailing: const Text('WebDAV'),
          onTap: () => context.push('/settings/remote-library'),
        ),
        _tile(
          context,
          icon: Icons.audiotrack,
          title: '扫描格式',
          trailing: Text('${settings?.scanFormats.length ?? 0} 种'),
          onTap: () => _pickScanFormats(context, ref, settings),
        ),
        _tile(
          context,
          icon: Icons.timer,
          title: '排除短音频（秒）',
          trailing: Text('${settings?.libraryMinDurationSeconds ?? 0}'),
          onTap: () => _pickMinDuration(context, ref, settings),
        ),
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
          trailing: Text(settings?.downloadQuality ?? '320k'),
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
      ],
      SettingsSection.other => [
        _tile(
          context,
          icon: Icons.query_stats,
          title: '听歌统计',
          trailing: const Text(''),
          onTap: () => context.push('/settings/statistics'),
        ),
        _tile(
          context,
          icon: Icons.info_outline,
          title: '关于 XY Music',
          trailing: const Text('1.3.1'),
          onTap: () => context.push('/settings/about'),
        ),
        _categoryTile(
          context,
          icon: Icons.bug_report_outlined,
          title: '日志与调试',
          subtitle: '日志保存、筛选与导出',
          route: '/settings/logs-debug',
        ),
        _tile(
          context,
          icon: Icons.feedback_outlined,
          title: '问题反馈',
          trailing: const Text('提交与查看'),
          onTap: () => context.push('/settings/feedback'),
        ),
      ],
      SettingsSection.logsDebug => [
        _tile(
          context,
          icon: Icons.description_outlined,
          title: '日志',
          trailing: const Text('保存与导出'),
          onTap: () => context.push('/settings/logs'),
        ),
      ],
      SettingsSection.feedback => const [],
    };

    return Scaffold(
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
      body: ListView(
        padding: EdgeInsets.only(
          top: section == SettingsSection.root ? 8 : 4,
          bottom: 24,
        ),
        children: [
          if (section == SettingsSection.root) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: TextField(
                controller: _searchController,
                textInputAction: TextInputAction.search,
                onChanged: (value) => setState(() => _query = value.trim()),
                decoration: InputDecoration(
                  hintText: '搜索设置',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清除',
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                        ),
                ),
              ),
            ),
            if (_query.isNotEmpty) ..._searchResultTiles(context),
          ],
          if (section != SettingsSection.root || _query.isEmpty) ...children,
        ],
      ),
    );
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
    return ListTile(
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
        entry.level == 1 ? '一级分类' : entry.path.join(' › '),
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
      onTap: () => context.push(entry.route),
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
    SettingsSection.playback => '播放',
    SettingsSection.playbackDetail => '歌词',
    SettingsSection.lyrics => '播放详情页歌词',
    SettingsSection.desktopLyrics => '桌面歌词',
    SettingsSection.library => '音乐库',
    SettingsSection.download => '下载',
    SettingsSection.other => '其他',
    SettingsSection.logsDebug => '日志与调试',
    SettingsSection.feedback => '问题反馈',
  };

  Widget _categoryTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required String route,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      minTileHeight: 68,
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: scheme.primaryContainer.withValues(alpha: .72),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: scheme.onPrimaryContainer, size: 22),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Icon(Icons.chevron_right, color: scheme.outline),
      onTap: () => context.push(route),
    );
  }

  Widget _tile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required Widget trailing,
    VoidCallback? onTap,
  }) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
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
      onTap: onTap,
    );
  }

  Widget _switchTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      secondary: Icon(icon),
      title: Text(title),
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
      secondary: Icon(
        Icons.auto_awesome_outlined,
        color: enabled ? null : Theme.of(context).disabledColor,
      ),
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

  /// 歌词字号调整弹窗：滑杆 + 歌词预览，与播放详情页更多菜单中的
  /// “歌词字号”共用同一份设置，实时生效。
  Future<void> _showLyricFontSizeSheet(BuildContext context, WidgetRef ref) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _SettingsLyricFontSizeSheet(
        initial:
            ref.read(settingsProvider).valueOrNull?.lyricFontSize ?? 18.0,
        onChanged: (value) =>
            ref.read(settingsProvider.notifier).setLyricFontSize(value),
      ),
    );
  }

  String _playerDetailBackgroundLabel(PlayerDetailBackgroundMode mode) =>
      switch (mode) {
        PlayerDetailBackgroundMode.coverBlur => '封面模糊',
        PlayerDetailBackgroundMode.wallpaperBlur => '壁纸模糊',
        PlayerDetailBackgroundMode.flowingLight => '流光',
        PlayerDetailBackgroundMode.customImage => '自定义图片',
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
      final started = await DesktopLyricsBridge.setEnabled(true);
      if (!started) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('请授予悬浮窗权限后再开启桌面歌词')));
        }
        return;
      }
    } else {
      await DesktopLyricsBridge.setEnabled(false);
    }
    await notifier.setDesktopLyricsEnabled(enabled);
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
        settings?.desktopLyricsTranslationFontSize ?? 13;
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

  Future<void> _pickDesktopLyricsColor(
    BuildContext context,
    WidgetRef ref, {
    required String title,
    required int current,
    required Future<void> Function(int) save,
  }) async {
    const colors = [
      0xFFFFFFFF,
      0xFFE1E1E6,
      0xFFFFCDD2,
      0xFFFFE0B2,
      0xFFFFF9C4,
      0xFFC8E6C9,
      0xFFB3E5FC,
      0xFFD1C4E9,
      0xFF263238,
      0xFF37474F,
      0xFF4A148C,
      0xFF880E4F,
      0xFF7F0000,
      0xFF0D47A1,
      0xFF01579B,
      0xFF1B5E20,
      0xFF33691E,
      0xFF4E342E,
      0xFF000000,
      0xFF18181C,
    ];
    final choice = await showModalBottomSheet<int>(
      context: context,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final color in colors)
                  InkWell(
                    onTap: () => Navigator.pop(sheetContext, color),
                    borderRadius: BorderRadius.circular(20),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Color(color),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: color == current
                              ? Theme.of(sheetContext).colorScheme.primary
                              : Theme.of(sheetContext).colorScheme.outline,
                          width: color == current ? 3 : 1,
                        ),
                      ),
                      child: color == current
                          ? const Icon(
                              Icons.check,
                              color: Colors.white,
                              size: 20,
                            )
                          : null,
                    ),
                  ),
                InkWell(
                  onTap: () => Navigator.pop(sheetContext, -1),
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Theme.of(sheetContext).colorScheme.outline,
                      ),
                    ),
                    child: const Icon(Icons.colorize_outlined, size: 20),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (choice == -1 && context.mounted) {
      final custom = await showDialog<int>(
        context: context,
        builder: (_) => _CustomDesktopColorDialog(initial: current),
      );
      if (custom != null) await save(custom);
    } else if (choice != null) {
      await save(choice);
    }
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
      builder: (_) => _choiceSheet(
        context,
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
      builder: (_) => Padding(
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
                    onTap: () => Navigator.pop(context, c),
                    borderRadius: BorderRadius.circular(20),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Color(c),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: c == cur
                              ? Theme.of(context).colorScheme.primary
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
              ],
            ),
          ],
        ),
      ),
    );
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
    final result = await showModalBottomSheet<_CustomBackgroundResult>(
      context: context,
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
                    '图片仅保存在本机，不会上传到服务器。',
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
                      OutlinedButton.icon(
                        onPressed: pickImage,
                        icon: const Icon(Icons.upload_file_outlined),
                        label: const Text('选择图片'),
                      ),
                      const Spacer(),
                      if (imagePath.isNotEmpty)
                        TextButton(
                          onPressed: () => setSheetState(() => imagePath = ''),
                          child: const Text('恢复默认'),
                        ),
                      const SizedBox(width: 6),
                      FilledButton(
                        onPressed: () => Navigator.pop(
                          sheetContext,
                          _CustomBackgroundResult(imagePath, blur),
                        ),
                        child: const Text('应用'),
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
    if (result == null || !context.mounted) return;
    final notifier = ref.read(settingsProvider.notifier);
    await notifier.setCustomBackgroundPath(result.path);
    await notifier.setCustomBackgroundBlur(result.blur);
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
    final choice = await showModalBottomSheet<_Choice>(
      context: context,
      builder: (_) => _choiceSheet(
        context,
        const [
          _Choice('128k', '128k'),
          _Choice('192k', '192k'),
          _Choice('320k', '320k'),
          _Choice('标准无损', 'flac'),
        ],
        cur,
        labelOf: (v) => v as String,
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

  Future<void> _pickMinDuration(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    final cur = s?.libraryMinDurationSeconds ?? 0;
    final choices = const [
      _Choice('不排除', 0),
      _Choice('10 秒', 10),
      _Choice('30 秒', 30),
      _Choice('60 秒', 60),
    ];
    final choice = await showModalBottomSheet<_Choice>(
      context: context,
      builder: (_) => _choiceSheet(
        context,
        choices,
        cur,
        labelOf: (v) => switch (v) {
          0 => '不排除',
          10 => '10 秒',
          30 => '30 秒',
          60 => '60 秒',
          _ => '$v 秒',
        },
      ),
    );
    if (choice != null) {
      await ref
          .read(settingsProvider.notifier)
          .setLibraryMinDurationSeconds(choice.value as int);
    }
  }

  /// 扫描格式多选：勾选要扫描入库的音频格式（至少保留一种）。
  Future<void> _pickScanFormats(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    final selected = {...(s?.scanFormats ?? kSupportedScanFormats)};
    const labels = {
      'flac': 'FLAC（无损）',
      'mp3': 'MP3',
      'wav': 'WAV（无损）',
      'aac': 'AAC',
      'm4a': 'M4A / ALAC',
      'ogg': 'OGG / Vorbis',
      'aiff': 'AIFF',
    };
    final result = await showModalBottomSheet<Set<String>>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setModalState) {
          return SafeArea(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Text(
                      '扫描格式',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  for (final fmt in kSupportedScanFormats)
                    CheckboxListTile(
                      title: Text(labels[fmt] ?? fmt.toUpperCase()),
                      value: selected.contains(fmt),
                      onChanged: (v) {
                        setModalState(() {
                          if (v == true) {
                            selected.add(fmt);
                          } else {
                            selected.remove(fmt);
                          }
                        });
                      },
                    ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('取消'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: selected.isEmpty
                              ? null
                              : () => Navigator.pop(context, selected),
                          child: const Text('确定'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (result != null && result.isNotEmpty) {
      final ordered = kSupportedScanFormats
          .where((f) => result.contains(f))
          .toList();
      await ref.read(settingsProvider.notifier).setScanFormats(ordered);
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
    );
  }
}

class _CustomDesktopColorDialog extends StatefulWidget {
  const _CustomDesktopColorDialog({required this.initial});

  final int initial;

  @override
  State<_CustomDesktopColorDialog> createState() =>
      _CustomDesktopColorDialogState();
}

class _CustomDesktopColorDialogState extends State<_CustomDesktopColorDialog> {
  late double _red;
  late double _green;
  late double _blue;

  @override
  void initState() {
    super.initState();
    final color = Color(widget.initial);
    _red = (color.r * 255).roundToDouble();
    _green = (color.g * 255).roundToDouble();
    _blue = (color.b * 255).roundToDouble();
  }

  Color get _color =>
      Color.fromARGB(255, _red.round(), _green.round(), _blue.round());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('自定义颜色'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: double.infinity,
              height: 52,
              decoration: BoxDecoration(
                color: _color,
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            const SizedBox(height: 12),
            _channelSlider('红', _red, Colors.red, (value) {
              setState(() => _red = value);
            }),
            _channelSlider('绿', _green, Colors.green, (value) {
              setState(() => _green = value);
            }),
            _channelSlider('蓝', _blue, Colors.blue, (value) {
              setState(() => _blue = value);
            }),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _color.toARGB32()),
          child: const Text('应用'),
        ),
      ],
    );
  }

  Widget _channelSlider(
    String label,
    double value,
    Color activeColor,
    ValueChanged<double> onChanged,
  ) {
    return Row(
      children: [
        SizedBox(width: 26, child: Text(label)),
        Expanded(
          child: Slider(
            value: value,
            min: 0,
            max: 255,
            divisions: 255,
            activeColor: activeColor,
            onChanged: onChanged,
          ),
        ),
        SizedBox(width: 30, child: Text(value.round().toString())),
      ],
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

class _SidebarLayoutEditor extends StatelessWidget {
  const _SidebarLayoutEditor({required this.settings, required this.notifier});

  final AppSettings settings;
  final SettingsNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final order = normalizeSidebarItemOrder(
      settings.sidebarItemOrder,
    ).where((id) => id != kSidebarSettings).toList();
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

  String _sidebarLabel(String id) => switch (id) {
    kSidebarHome => '首页',
    kSidebarExplore => '探索',
    kSidebarLocalMusic => '本地音乐',
    kSidebarFavorites => '我的收藏',
    kSidebarRecent => '最近播放',
    kSidebarPlugins => '插件管理',
    kSidebarAccount => '账号',
    kSidebarRecognize => '听歌识曲',
    kSidebarPlaylists => '管理全部歌单',
    kSidebarSettings => '设置',
    _ => id,
  };

  IconData _sidebarIcon(String id) => switch (id) {
    kSidebarHome => Icons.home_outlined,
    kSidebarExplore => Icons.explore_outlined,
    kSidebarLocalMusic => Icons.music_note_outlined,
    kSidebarFavorites => Icons.favorite_border_rounded,
    kSidebarRecent => Icons.history_rounded,
    kSidebarPlugins => Icons.extension_outlined,
    kSidebarAccount => Icons.account_circle_outlined,
    kSidebarRecognize => Icons.mic_none_rounded,
    kSidebarPlaylists => Icons.queue_music_rounded,
    kSidebarSettings => Icons.settings_outlined,
    _ => Icons.circle_outlined,
  };
}

class _Choice {
  final String label;
  final dynamic value;
  const _Choice(this.label, this.value);
}

/// 歌词字号调整弹窗：滑杆 + 歌词预览。拖动即写入设置，
/// 播放详情页歌词实时使用新字号渲染。
class _SettingsLyricFontSizeSheet extends StatefulWidget {
  const _SettingsLyricFontSizeSheet({
    required this.initial,
    required this.onChanged,
  });

  final double initial;
  final ValueChanged<double> onChanged;

  @override
  State<_SettingsLyricFontSizeSheet> createState() =>
      _SettingsLyricFontSizeSheetState();
}

class _SettingsLyricFontSizeSheetState
    extends State<_SettingsLyricFontSizeSheet> {
  late double _value;

  @override
  void initState() {
    super.initState();
    _value = widget.initial;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.format_size_outlined, color: scheme.primary),
              const SizedBox(width: 12),
              const Text('歌词字号', style: TextStyle(fontSize: 16)),
              const Spacer(),
              Text(
                _value.toStringAsFixed(0),
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: scheme.primary,
                ),
              ),
            ],
          ),
          Slider(
            value: _value,
            min: 12,
            max: 32,
            divisions: 20,
            label: _value.toStringAsFixed(0),
            onChanged: (value) {
              setState(() => _value = value);
              widget.onChanged(value);
            },
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: .5),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '正在播放的歌词行',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: (_value + 6).clamp(12.0, 32.0),
                    height: 1.3,
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '其他歌词行',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: _value,
                    height: 1.3,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface.withValues(alpha: .45),
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '翻译歌词行',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: (_value - 5).clamp(10.0, 26.0),
                    color: scheme.onSurface.withValues(alpha: .4),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CustomBackgroundResult {
  const _CustomBackgroundResult(this.path, this.blur);

  final String path;
  final double blur;
}
