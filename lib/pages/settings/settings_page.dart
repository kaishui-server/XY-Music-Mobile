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
import '../../src/navigation/sidebar_controller.dart';
import '../../src/player/desktop_lyrics.dart';
import '../../src/player/mini_player_overlay.dart';
import '../../src/playlists/playlists_provider.dart';
import '../../src/plugins/plugin_runtime.dart';
import '../../src/recent/recent_provider.dart';
import '../../src/ui/xy_surface.dart';
import '../../src/widgets/color_picker_sheet.dart';
import '../../src/widgets/frosted_search_field.dart';
import '../../src/widgets/top_notice.dart';

enum SettingsSection {
  root,
  account,
  appearance,
  layout,
  sidebarLayout,
  bottomBar,
  playback,
  playbackDetail,
  lyrics,
  desktopLyrics,
  library,
  download,
  backup,
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
    keywords: '主题 模式 颜色 深色 浅色 背景 图片 模糊 字体',
  ),
  SettingsSearchEntry(
    title: '播放',
    path: ['播放'],
    route: '/settings/playback',
    icon: Icons.play_circle_outline_rounded,
    keywords: '音量 音质 屏幕常亮 封面 歌单',
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
    title: '云端音乐',
    path: ['云端音乐'],
    route: '/cloud-music',
    icon: Icons.cloud_outlined,
    keywords: '网盘 Alist OpenList 挂载 云端 同步 远程',
  ),
  SettingsSearchEntry(
    title: '音乐库',
    path: ['音乐库'],
    route: '/settings/library',
    icon: Icons.library_music_outlined,
    keywords: '本地 扫描 文件夹',
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
    title: '备份与恢复',
    path: ['备份与恢复'],
    route: '/settings/backup',
    icon: Icons.backup_outlined,
    keywords: '备份 恢复 导出 导入 迁移 换机 歌单 收藏',
  ),
  SettingsSearchEntry(
    title: '其他',
    path: ['其他'],
    route: '/settings/other',
    icon: Icons.tune_rounded,
    keywords: '统计 关于 版本',
  ),
  SettingsSearchEntry(
    title: '存储与缓存',
    path: ['存储与缓存'],
    route: '/settings/storage',
    icon: Icons.cleaning_services_outlined,
    keywords: '缓存 清理 空间 占用 封面 临时文件',
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
    title: '自定义字体',
    path: ['外观', '自定义字体'],
    route: '/settings/appearance',
    icon: Icons.font_download_outlined,
    keywords: '字体 ttf otf 全局 文字 更换',
  ),
  SettingsSearchEntry(
    title: '播放详情页背景',
    path: ['外观', '播放详情页背景'],
    route: '/settings/appearance',
    icon: Icons.wallpaper_outlined,
    keywords: '封面模糊 壁纸模糊 流光 自定义图片',
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
    title: '侧边栏位置',
    path: ['布局', '顶栏布局', '侧边栏位置'],
    route: '/settings/layout',
    icon: Icons.swap_horiz_rounded,
    keywords: '左上 右上 菜单按钮',
  ),
  SettingsSearchEntry(
    title: '侧边栏布局',
    path: ['布局', '侧边栏布局'],
    route: '/settings/sidebar-layout',
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
    title: '播放歌曲时',
    path: ['播放', '播放歌曲时'],
    route: '/settings/playback',
    icon: Icons.queue_music_outlined,
    keywords: '入队 播放队列 整个列表 仅此歌曲 单曲',
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
    title: '单击歌词调整进度',
    path: ['歌词', '单击歌词调整进度'],
    route: '/settings/playback-detail',
    icon: Icons.touch_app_outlined,
    keywords: '点击歌词 跳转 进度 seek',
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
    title: '挂载网盘源',
    path: ['云端音乐', '挂载网盘源'],
    route: '/cloud-music',
    icon: Icons.dns_outlined,
    keywords: 'TVBox Alist OpenList 网盘 服务器 挂载',
  ),
  SettingsSearchEntry(
    title: '播放缓存',
    path: ['云端音乐', '播放缓存'],
    route: '/cloud-music',
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
      // 侧边栏布局与自定义底栏体量大，改为独立页面，根页只留入口卡片。
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
          icon: Icons.volume_up,
          title: '音量',
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
        _tile(
          context,
          icon: Icons.high_quality,
          title: '在线默认音质',
          trailing: Text(
            qualityDisplayLabel(settings?.onlineDefaultQuality ?? '320k'),
          ),
          onTap: () => _pickQuality(context, ref, settings, isOnline: true),
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
          icon: Icons.image_not_supported_outlined,
          title: '歌单歌曲加载封面',
          value: settings?.showPlaylistSongCovers ?? true,
          onChanged: (v) => notifier.setShowPlaylistSongCovers(v),
        ),
        _switchTile(
          context,
          icon: Icons.screen_lock_rotation,
          title: '保持屏幕常亮',
          value: settings?.keepScreenOn ?? true,
          onChanged: (v) => notifier.setKeepScreenOn(v),
        ),
        _switchTile(
          context,
          icon: Icons.picture_in_picture_alt_outlined,
          title: '迷你播放器浮窗',
          subtitle: '通知栏单击媒体卡片弹出浮窗，封面/进度条/切歌按钮可直接操作',
          value: settings?.miniPlayerOverlayEnabled ?? false,
          onChanged: (v) => _setMiniPlayerOverlay(context, ref, v),
        ),
      ],
      SettingsSection.playbackDetail => [
        _switchTile(
          context,
          icon: Icons.touch_app_outlined,
          title: '单击歌词调整进度',
          value: settings?.lyricTapSeek ?? true,
          onChanged: (v) => notifier.setLyricTapSeek(v),
        ),
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
            (settings?.lyricFontSize ?? 22.0).toStringAsFixed(0),
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
        _desktopLyricsPositionTile(context, settings, notifier),
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
            value: settings?.desktopLyricsTranslationFontSize ?? 12,
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
        _tile(
          context,
          icon: Icons.info_outline,
          title: '关于 XY Music',
          titleStyle: const TextStyle(fontWeight: FontWeight.w700),
          // 原生通道读取实际版本（构建时来自 pubspec.yaml），避免
          // 硬编码版本号随版本升级过期。
          trailing: Text(
            ref.watch(appVersionProvider).valueOrNull ?? '',
          ),
          onTap: () => context.push('/settings/about'),
        ),
        _categoryTile(
          context,
          title: '日志与调试',
          subtitle: '日志保存、筛选与导出',
          route: '/settings/logs-debug',
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

  /// 根页卡片流：入口型分类做独立卡片，普通分类标题写在大框上方、
  /// 内容直接内嵌展示（与子页面共用 _sectionTiles 的内容列表）。
  List<Widget> _rootCards(
    BuildContext context, {
    required AppSettings? settings,
    required SettingsNotifier notifier,
    required AuthState auth,
    required AsyncValue<bool> dynamicColorSupported,
  }) {
    List<Widget> tiles(SettingsSection section) => _sectionTiles(
      context,
      section: section,
      settings: settings,
      notifier: notifier,
      auth: auth,
      dynamicColorSupported: dynamicColorSupported,
    );
    return [
      _entryCard(
        context,
        title: '账号',
        subtitle: auth.isLoggedIn ? auth.user!.nickname : '登录、注册与账号安全',
        route: '/account?from=settings',
      ),
      _entryCard(
        context,
        title: '插件管理',
        subtitle: '安装、启用与管理音乐插件',
        route: '/settings/plugins',
      ),
      _groupHeader(context, '个性化'),
      _entryCard(
        context,
        title: '外观',
        subtitle: '主题、颜色、字体、壁纸与封面样式',
        route: '/settings/appearance',
      ),
      _entryCard(
        context,
        title: '布局',
        subtitle: '顶栏位置与首页模块',
        route: '/settings/layout',
      ),
      _entryCard(
        context,
        title: '侧边栏布局',
        subtitle: '菜单显示、隐藏与拖拽排序',
        route: '/settings/sidebar-layout',
      ),
      _entryCard(
        context,
        title: '自定义底栏',
        subtitle: '挑选底栏目的地并拖动排序',
        route: '/settings/bottom-bar',
      ),
      _sectionCard(
        context,
        title: '播放',
        children: tiles(SettingsSection.playback),
      ),
      _sectionCard(
        context,
        title: '歌词',
        children: tiles(SettingsSection.playbackDetail),
      ),
      _sectionCard(
        context,
        title: '下载',
        children: tiles(SettingsSection.download),
      ),
      _entryCard(
        context,
        title: '备份与恢复',
        subtitle: '导出或导入歌单、收藏、本地曲库、插件与设置',
        route: '/settings/backup',
      ),
      _entryCard(
        context,
        title: '存储与缓存',
        subtitle: '查看并清理封面、播放缓存与临时文件',
        route: '/settings/storage',
      ),
      _sectionCard(
        context,
        title: '其他',
        children: tiles(SettingsSection.other),
      ),
      _entryCard(
        context,
        title: '问题反馈',
        subtitle: '提交问题、建议并查看处理进度',
        route: '/settings/feedback',
      ),
    ];
  }

  /// 分组标题：把若干入口卡片归入同一大块（如「个性化」下的外观、布局）。
  Widget _groupHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 7),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  /// 入口卡片：需要独立页面的分类（无图标），点击进入。
  Widget _entryCard(
    BuildContext context, {
    required String title,
    required String subtitle,
    required String route,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => context.push(route),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                          fontWeight: FontWeight.w700,
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
                Icon(Icons.chevron_right_rounded, color: scheme.outline),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 内容卡片：分类名称写在大框上方，设置项直接展示在框内。
  Widget _sectionCard(
    BuildContext context, {
    required String title,
    required List<Widget> children,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 7),
            child: Text(
              title,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: scheme.primary,
              ),
            ),
          ),
          Material(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            child: Column(children: children),
          ),
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
    SettingsSection.sidebarLayout => '侧边栏布局',
    SettingsSection.bottomBar => '自定义底栏',
    SettingsSection.playback => '播放',
    SettingsSection.playbackDetail => '歌词',
    SettingsSection.lyrics => '播放详情页歌词',
    SettingsSection.desktopLyrics => '桌面歌词',
    SettingsSection.library => '音乐库',
    SettingsSection.download => '下载',
    SettingsSection.backup => '备份与恢复',
    SettingsSection.other => '其他',
    SettingsSection.logsDebug => '日志与调试',
    SettingsSection.feedback => '问题反馈',
  };

  Widget _categoryTile(
    BuildContext context, {
    required String title,
    required String subtitle,
    required String route,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      minTileHeight: 64,
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Icon(Icons.chevron_right, color: scheme.outline),
      onTap: () => context.push(route),
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
    return ListTile(
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
      onTap: onTap,
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

  /// 歌词字号调整弹窗：双滑杆 + 歌词预览，与播放详情页更多菜单中的
  /// “歌词字号”共用同一份设置，实时生效；主歌词与迷你歌词字号独立调整。
  Future<void> _showLyricFontSizeSheet(BuildContext context, WidgetRef ref) {
    return showModalBottomSheet<void>(
      context: context,
      // 自定义底栏/迷你播放栏叠在 Shell 顶层 Stack；使用根 Navigator
      // 让弹窗覆盖它们，避免底部内容被悬浮底栏遮挡。
      useRootNavigator: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _SettingsLyricFontSizeSheet(
        initial: ref.read(settingsProvider).valueOrNull?.lyricFontSize ?? 22.0,
        initialMini:
            ref.read(settingsProvider).valueOrNull?.miniLyricFontSize ?? 14.0,
        onChanged: (value) =>
            ref.read(settingsProvider.notifier).setLyricFontSize(value),
        onMiniChanged: (value) =>
            ref.read(settingsProvider.notifier).setMiniLyricFontSize(value),
      ),
    );
  }

  String _playerDetailBackgroundLabel(PlayerDetailBackgroundMode mode) =>
      switch (mode) {
        PlayerDetailBackgroundMode.coverBlur => '流光',
        PlayerDetailBackgroundMode.wallpaperBlur => '壁纸模糊',
        PlayerDetailBackgroundMode.flowingLight => '流光',
        PlayerDetailBackgroundMode.customImage => '自定义图片',
        PlayerDetailBackgroundMode.particle => '流光',
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

  /// 迷你播放器浮窗开关：开启前先让原生校验悬浮窗权限（未授权会拉起授权
  /// 页），通过后再写入设置；写入设置会触发根节点同步显示浮窗。
  Future<void> _setMiniPlayerOverlay(
    BuildContext context,
    WidgetRef ref,
    bool enabled,
  ) async {
    if (enabled) {
      final accepted = await MiniPlayerOverlayBridge.setEnabled(true);
      if (!accepted) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('请授予悬浮窗权限后再开启迷你播放器浮窗')));
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
      useRootNavigator: true,
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
                          _CustomBackgroundResult(imagePath, blur, fade),
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
      useRootNavigator: true,
      builder: (sheetContext) => _choiceSheet(
        sheetContext,
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
      useRootNavigator: true,
      builder: (sheetContext) => StatefulBuilder(
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
  kSidebarTestPage => '测试页面',
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
  kSidebarTestPage => Icons.science_outlined,
  kSidebarSettings => Icons.settings_outlined,
  _ => Icons.circle_outlined,
};

class _Choice {
  final String label;
  final dynamic value;
  const _Choice(this.label, this.value);
}

/// 歌词字号调整弹窗：双滑杆（主歌词 + 迷你歌词）+ 歌词预览。拖动即写入
/// 设置，播放详情页歌词实时使用新字号渲染；两类字号彼此独立。
class _SettingsLyricFontSizeSheet extends StatefulWidget {
  const _SettingsLyricFontSizeSheet({
    required this.initial,
    required this.initialMini,
    required this.onChanged,
    required this.onMiniChanged,
  });

  final double initial;
  final double initialMini;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onMiniChanged;

  @override
  State<_SettingsLyricFontSizeSheet> createState() =>
      _SettingsLyricFontSizeSheetState();
}

class _SettingsLyricFontSizeSheetState
    extends State<_SettingsLyricFontSizeSheet> {
  late double _value;
  late double _miniValue;

  @override
  void initState() {
    super.initState();
    _value = widget.initial;
    _miniValue = widget.initialMini;
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
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.subtitles_outlined, color: scheme.primary),
              const SizedBox(width: 12),
              const Text('迷你歌词字号', style: TextStyle(fontSize: 16)),
              const Spacer(),
              Text(
                _miniValue.toStringAsFixed(0),
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: scheme.primary,
                ),
              ),
            ],
          ),
          Slider(
            value: _miniValue,
            min: 10,
            max: 24,
            divisions: 14,
            label: _miniValue.toStringAsFixed(0),
            onChanged: (value) {
              setState(() => _miniValue = value);
              widget.onMiniChanged(value);
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
                const SizedBox(height: 5),
                Text(
                  '迷你歌词行',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: _miniValue,
                    color: scheme.onSurface.withValues(alpha: .5),
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
  const _CustomBackgroundResult(this.path, this.blur, this.fade);

  final String path;
  final double blur;
  final double fade;
}
