import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/core/settings.dart';
import '../../src/auth/auth_provider.dart';
import '../../src/navigation/sidebar_controller.dart';

enum SettingsSection {
  root,
  account,
  appearance,
  playback,
  playbackDetail,
  lyrics,
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
    route: '/account',
    icon: Icons.manage_accounts_outlined,
    keywords: '登录 注册 账号安全 退出',
  ),
  SettingsSearchEntry(
    title: '外观',
    path: ['外观'],
    route: '/settings/appearance',
    icon: Icons.palette_outlined,
    keywords: '主题 模式 颜色 深色 浅色',
  ),
  SettingsSearchEntry(
    title: '播放',
    path: ['播放'],
    route: '/settings/playback',
    icon: Icons.play_circle_outline_rounded,
    keywords: '音量 音质 屏幕常亮',
  ),
  SettingsSearchEntry(
    title: '播放详情页',
    path: ['播放详情页'],
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
    title: '其他',
    path: ['其他'],
    route: '/settings/other',
    icon: Icons.tune_rounded,
    keywords: '统计 关于 版本',
  ),
  SettingsSearchEntry(
    title: '账号与安全',
    path: ['账号', '账号与安全'],
    route: '/account',
    icon: Icons.account_circle_outlined,
    keywords: '登录 注册 验证码 退出',
  ),
  SettingsSearchEntry(
    title: '歌词',
    path: ['播放详情页', '歌词'],
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
    path: ['播放详情页', '歌词', '显示翻译'],
    route: '/settings/lyrics',
    icon: Icons.translate_outlined,
  ),
  SettingsSearchEntry(
    title: '逐字动效',
    path: ['播放详情页', '歌词', '逐字动效'],
    route: '/settings/lyrics',
    icon: Icons.spellcheck_outlined,
    keywords: '逐字歌词 动画',
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

    final children = switch (section) {
      SettingsSection.root => [
        _categoryTile(
          context,
          icon: Icons.manage_accounts_outlined,
          title: '账号',
          subtitle: auth.isLoggedIn ? auth.user!.nickname : '登录、注册与账号安全',
          route: '/account',
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
          icon: Icons.play_circle_outline_rounded,
          title: '播放',
          subtitle: '音量、在线音质与屏幕常亮',
          route: '/settings/playback',
        ),
        _categoryTile(
          context,
          icon: Icons.queue_music_outlined,
          title: '播放详情页',
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
          onTap: () => context.push('/account'),
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
          title: '歌词',
          trailing: const Text(''),
          onTap: () => context.push('/settings/lyrics'),
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
          trailing: Text(
            settings?.downloadPath == null || settings!.downloadPath.isEmpty
                ? '默认'
                : '自定义',
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
          trailing: const Text('1.0.0'),
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
        leading: section == SettingsSection.root
            ? const AppSidebarMenuButton()
            : null,
        title: Text(_pageTitle),
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
    SettingsSection.playback => '播放',
    SettingsSection.playbackDetail => '播放详情页',
    SettingsSection.lyrics => '歌词',
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
    final controller = TextEditingController(text: cur);
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
              decoration: const InputDecoration(
                labelText: '路径',
                hintText: '例如 /storage/emulated/0/Music',
                border: OutlineInputBorder(),
              ),
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
                  onPressed: () => Navigator.pop(ctx, controller.text.trim()),
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

class _Choice {
  final String label;
  final dynamic value;
  const _Choice(this.label, this.value);
}
