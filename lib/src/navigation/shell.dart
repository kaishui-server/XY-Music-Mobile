import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../playlists/playlists_provider.dart';
import '../player/player_provider.dart';
import '../core/settings.dart';
import '../ui/xy_theme.dart';
import '../ui/xy_surface.dart';
import '../widgets/mini_player_bar.dart';
import '../widgets/top_notice.dart';
import 'sidebar_controller.dart';

// 暂时从移动端侧栏隐藏，保留路由和组件，之后可直接恢复。
const _showArtistAndAlbumShortcuts = false;
const _showPlaylistSection = false;
int? _activeRelinkProposalId;

/// 侧边栏与自定义底栏共用的目的地映射（id → 名称/图标/路由）。
const _sidebarDestinations = <String, _SidebarDestination>{
  kSidebarHome: _SidebarDestination('首页', Icons.home_outlined, '/home'),
  kSidebarExplore: _SidebarDestination(
    '探索',
    Icons.explore_outlined,
    '/home/explore',
  ),
  kSidebarLocalMusic: _SidebarDestination(
    '本地音乐',
    Icons.music_note_outlined,
    '/local-music',
  ),
  kSidebarCloudMusic: _SidebarDestination(
    '云端音乐',
    Icons.cloud_outlined,
    '/cloud-music',
  ),
  kSidebarFavorites: _SidebarDestination(
    '我的收藏',
    Icons.favorite_border_rounded,
    '/home/favorites',
  ),
  kSidebarRecent: _SidebarDestination(
    '最近播放',
    Icons.history_rounded,
    '/home/recent',
  ),
  kSidebarPlugins: _SidebarDestination(
    '插件管理',
    Icons.extension_outlined,
    '/settings/plugins?from=sidebar',
  ),
  kSidebarAccount: _SidebarDestination(
    '账号',
    Icons.account_circle_outlined,
    '/account?from=sidebar',
  ),
  kSidebarRecognize: _SidebarDestination(
    '听歌识曲',
    Icons.mic_none_rounded,
    '/home/recognize',
  ),
  kSidebarPlaylists: _SidebarDestination(
    '管理全部歌单',
    Icons.queue_music_rounded,
    '/home/playlists',
  ),
  kSidebarDownloads: _SidebarDestination(
    '下载管理',
    Icons.download_rounded,
    '/settings/downloads',
  ),
  kSidebarSettings: _SidebarDestination(
    '设置',
    Icons.settings_outlined,
    '/settings',
  ),
};

/// 目的地是否对应当前路由（忽略查询参数，支持子路由高亮）。
bool _destinationSelected(String currentPath, String path) {
  final normalized = path.split('?').first;
  if (normalized == '/home') return currentPath == '/home';
  if (!(currentPath == normalized || currentPath.startsWith('$normalized/'))) {
    return false;
  }
  // 子路由有独立入口时（如 /settings/downloads 相对 /settings）只高亮
  // 更长前缀的那个入口，避免“下载管理”与“设置”同时点亮。
  for (final destination in _sidebarDestinations.values) {
    final other = destination.path.split('?').first;
    if (other.length > normalized.length &&
        (currentPath == other || currentPath.startsWith('$other/'))) {
      return false;
    }
  }
  return true;
}

/// 自定义底栏的高度与悬浮间距（迷你播放栏据此让位）。
const kBottomBarHeight = 60.0;
const kBottomBarBottomGap = 12.0;

/// 迷你播放栏高度与无底栏时距屏幕底部的间距（与 MiniPlayerBar 内部一致）。
const kMiniPlayerHeight = 64.0;
const kMiniPlayerBottomGap = 20.0;

/// 电脑端侧栏与迷你播放器在手机上的对应结构。
class AppShell extends ConsumerWidget {
  const AppShell({
    super.key,
    required this.navigationShell,
    required this.currentPath,
  });

  final StatefulNavigationShell navigationShell;
  final String currentPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<PlaybackRelinkProposal?>(playbackRelinkProposalProvider, (
      previous,
      next,
    ) {
      if (next == null || next.id == _activeRelinkProposalId) return;
      final dialogContext = appScaffoldKey.currentContext;
      if (dialogContext != null) {
        unawaited(_showPlaybackRelinkDialog(dialogContext, ref, next));
      }
    });
    ref.listen<PlaybackNoticeEvent?>(playbackNoticeEventProvider, (
      previous,
      next,
    ) {
      if (next == null) return;
      XyNotice.show(
        context,
        message: next.message,
        type: XyNoticeType.warning,
        duration: const Duration(seconds: 5),
      );
      ref.read(playbackNoticeEventProvider.notifier).state = null;
    });
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final showMiniPlayer = shouldShowMiniPlayerForPath(currentPath);
    // 迷你播放栏仅在「有歌在播」时真正渲染，注入的遮挡高度需同步，
    // 否则未播放时列表底部会多出一段空白。
    final miniPlayerVisible =
        showMiniPlayer &&
        ref.watch(playerProvider.select((state) => state.current != null));
    final sidebarOnRight =
        ref.watch(settingsProvider).valueOrNull?.sidebarPosition ==
        SidebarPosition.right;
    final shellSettings = ref.watch(settingsProvider).valueOrNull;
    final bottomBarItemIds =
        shellSettings?.bottomBarItemIds ?? const <String>[];
    final bottomBarVisible =
        (shellSettings?.bottomBarEnabled ?? false) &&
        bottomBarItemIds.length >= 2;
    // 悬浮元素（底栏+迷你播放栏）在系统安全区之上占用的总高度，注入
    // MediaQuery.padding.bottom：页面 SafeArea 或显式读取该值即可让
    // 底部内容不被悬浮元素遮挡（修复插件管理/本地音乐等页面被盖住）。
    final extraBottomPadding =
        (bottomBarVisible ? kBottomBarHeight + kBottomBarBottomGap * 2 : 0.0) +
        (miniPlayerVisible
            ? kMiniPlayerHeight +
                  (bottomBarVisible ? 0.0 : kMiniPlayerBottomGap)
            : 0.0);

    void navigate(String path) =>
        navigateFromSidebar(context, appScaffoldKey, path);

    final viewport = MediaQuery.sizeOf(context);
    // 宽松式横屏断点（宽 >= 高 × 1.05，含平板横持），与参考项目一致。
    final isLandscape = viewport.width >= viewport.height * 1.05;

    // 内容区：页面 + 悬浮底栏 + 迷你播放栏（横竖屏共用，横屏时位于
    // 侧栏右侧的剩余宽度内）。
    final content = Stack(
      children: [
        MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: MediaQuery.of(
              context,
            ).padding.copyWith(bottom: safeBottom + extraBottomPadding),
          ),
          child: navigationShell,
        ),
        if (bottomBarVisible)
          Positioned(
            left: 12,
            right: 12,
            bottom: safeBottom + kBottomBarBottomGap,
            child: XyBottomBar(
              itemIds: bottomBarItemIds,
              currentPath: currentPath,
            ),
          ),
        if (showMiniPlayer)
          AnimatedPositioned(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            left: 12,
            right: 12,
            bottom:
                safeBottom +
                (bottomBarVisible
                    ? kBottomBarHeight + kBottomBarBottomGap * 2
                    : 20),
            child: const MiniPlayerBar(),
          ),
      ],
    );

    return Scaffold(
      key: appScaffoldKey,
      extendBody: true,
      // 键盘避让交给各页面自己的 Scaffold：Shell 与页面是双层 Scaffold
      // 嵌套，若两层都默认避让 viewInsets，body 会被连续压缩两次
      // （表单被推到“键盘高度×2”处），键盘上方露出一块与键盘等大的
      // 浅色空白（观感即“白色遮挡”），所有机型必现。此处不避让，
      // 底栏/迷你播放栏在键盘弹出时被系统键盘自然覆盖。
      resizeToAvoidBottomInset: false,
      drawerScrimColor: Colors.black.withValues(alpha: 0.58),
      // 横屏已有常驻侧栏：禁用左缘拖出抽屉，避免与侧栏拖宽手势冲突。
      drawerEdgeDragWidth: isLandscape ? 0 : viewport.width * 0.16,
      // 右侧抽屉禁用边缘拖拽：Android 手势导航的右缘返回滑动会被抽屉
      // 拖拽抢占，产生“返回时页面叠加/侧栏残影”的问题。
      endDrawerEnableOpenDragGesture: false,
      drawer: sidebarOnRight
          ? null
          : XyMobileSidebar(currentPath: currentPath, onNavigate: navigate),
      endDrawer: sidebarOnRight
          ? XyMobileSidebar(currentPath: currentPath, onNavigate: navigate)
          : null,
      body: isLandscape
          ? Row(
              children: [
                if (!sidebarOnRight)
                  XyLandscapeSidebar(
                    currentPath: currentPath,
                    onNavigate: navigate,
                  ),
                Expanded(child: content),
                if (sidebarOnRight)
                  XyLandscapeSidebar(
                    currentPath: currentPath,
                    onNavigate: navigate,
                    onRight: true,
                  ),
              ],
            )
          : content,
    );
  }
}

/// 自定义底栏：与迷你播放栏同款的毛玻璃悬浮条，展示用户挑选的目的地。
/// 默认关闭，在「设置-布局」完成条目自定义（≥2 项）后自动开启。
/// 关闭「显示底栏文字」后仅显示图标（紧凑模式）。
class XyBottomBar extends ConsumerWidget {
  const XyBottomBar({
    super.key,
    required this.itemIds,
    required this.currentPath,
  });

  final List<String> itemIds;
  final String currentPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final showLabels = ref.watch(
      settingsProvider.select(
        (value) => value.valueOrNull?.bottomBarShowLabels ?? true,
      ),
    );
    final items = itemIds
        .map((id) => _sidebarDestinations[id])
        .whereType<_SidebarDestination>()
        .toList();
    return ClipRRect(
      borderRadius: BorderRadius.circular(XyRadii.large),
      child: BackdropFilter.grouped(
        filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          height: kBottomBarHeight,
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withValues(
              alpha: dark ? .34 : .48,
            ),
            borderRadius: BorderRadius.circular(XyRadii.large),
            border: Border.all(
              color: dark ? XyColors.darkBorder : XyColors.lightBorder,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: dark ? 0.3 : 0.09),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              for (final item in items)
                Expanded(
                  child: _BottomBarDestination(
                    destination: item,
                    selected: _destinationSelected(currentPath, item.path),
                    showLabel: showLabels,
                    onTap: () => context.go(item.path),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomBarDestination extends StatelessWidget {
  const _BottomBarDestination({
    required this.destination,
    required this.selected,
    required this.showLabel,
    required this.onTap,
  });

  final _SidebarDestination destination;
  final bool selected;
  final bool showLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = selected
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(XyRadii.medium),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(destination.icon, size: showLabel ? 22 : 24, color: color),
          if (showLabel) ...[
            const SizedBox(height: 3),
            Text(
              destination.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

Future<void> _showPlaybackRelinkDialog(
  BuildContext context,
  WidgetRef ref,
  PlaybackRelinkProposal proposal,
) async {
  if (_activeRelinkProposalId != null || !context.mounted) return;
  _activeRelinkProposalId = proposal.id;
  final replacement = proposal.replacement;
  final message = proposal.isLocal
      ? '该歌曲所属插件“${proposal.originalPluginName}”无法使用，检测到本地同名歌曲“${replacement.title}”，是否关联？'
      : '该歌曲所属插件“${proposal.originalPluginName}”无法使用，是否自动关联“${proposal.replacementSourceName}”插件的歌曲？';
  bool? accepted;
  try {
    accepted = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(
          proposal.isLocal
              ? Icons.library_music_outlined
              : Icons.extension_outlined,
        ),
        title: const Text('发现可替代音源'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('暂不关联'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确认关联'),
          ),
        ],
      ),
    );
  } finally {
    if (_activeRelinkProposalId == proposal.id) {
      _activeRelinkProposalId = null;
    }
  }
  if (!context.mounted) return;
  final notifier = ref.read(playerProvider.notifier);
  if (accepted == true) {
    await notifier.acceptRelinkProposal(proposal);
  } else {
    notifier.dismissRelinkProposal(proposal);
  }
}

bool shouldShowMiniPlayerForPath(String path) =>
    path != '/account' && path != '/settings' && !path.startsWith('/settings/');

/// 与电脑端 Sidebar 相同的信息层级，手机端使用抽屉承载。
class XyMobileSidebar extends ConsumerWidget {
  const XyMobileSidebar({
    super.key,
    required this.currentPath,
    required this.onNavigate,
  });

  final String currentPath;
  final ValueChanged<String> onNavigate;

  Future<void> _createPlaylist(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('新建歌单'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(hintText: '输入歌单名称'),
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name != null) await ref.read(playlistsProvider.notifier).create(name);
  }

  bool _selected(String path) => _destinationSelected(currentPath, path);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final settings = ref.watch(settingsProvider).valueOrNull;
    final playlists = ref.watch(playlistsProvider);
    final width = MediaQuery.sizeOf(context).width * 0.5;

    final hiddenItems =
        settings?.sidebarHiddenItems.toSet() ?? const <String>{};
    final showSettings = !hiddenItems.contains(kSidebarSettings);
    final showDownloads = !hiddenItems.contains(kSidebarDownloads);
    final primaryItems =
        normalizeSidebarItemOrder(
              settings?.sidebarItemOrder ?? kDefaultSidebarItemOrder,
            )
            .where(
              (id) =>
                  id != kSidebarSettings &&
                  id != kSidebarDownloads &&
                  !hiddenItems.contains(id),
            )
            .map((id) => _sidebarDestinations[id])
            .whereType<_SidebarDestination>()
            .toList();
    if (_showArtistAndAlbumShortcuts) {
      primaryItems.addAll(const [
        _SidebarDestination('歌手', Icons.person_outline_rounded, '/artists'),
        _SidebarDestination('专辑', Icons.album_outlined, '/albums'),
      ]);
    }

    return Drawer(
      width: width,
      elevation: 0,
      shape: const RoundedRectangleBorder(),
      backgroundColor: Colors.transparent,
      child: XyAppBackground(
        imagePath: settings?.customBackgroundPath ?? '',
        blur: settings?.customBackgroundBlur ?? 18,
        child: SafeArea(
          right: false,
          child: Column(
            children: [
              SizedBox(
                height: 62,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
                  child: Row(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Image.asset(
                            'assets/icon/app_icon.png',
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                      const SizedBox(width: 7),
                      const Expanded(
                        child: Text(
                          'XY Music',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w900,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭侧栏',
                        onPressed: () => Navigator.pop(context),
                        padding: EdgeInsets.zero,
                        constraints: BoxConstraints.tightFor(
                          width: 36,
                          height: 36,
                        ),
                        icon: const Icon(Icons.close_rounded, size: 20),
                      ),
                    ],
                  ),
                ),
              ),
              Divider(
                height: 1,
                color: dark ? XyColors.darkBorder : XyColors.lightBorder,
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(10, 10, 10, 20),
                  children: [
                    for (final item in primaryItems)
                      _SidebarTile(
                        destination: item,
                        selected: _selected(item.path),
                        onTap: () => onNavigate(item.path),
                      ),
                    if (_showPlaylistSection) ...[
                      const SizedBox(height: 17),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 0, 0, 6),
                        child: Row(
                          children: [
                            const Icon(Icons.expand_more_rounded, size: 16),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                '歌单 (${playlists.length})',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: '新建歌单',
                              onPressed: () => _createPlaylist(context, ref),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                width: 32,
                                height: 32,
                              ),
                              icon: const Icon(Icons.add_rounded, size: 19),
                            ),
                            IconButton(
                              tooltip: '导入歌单',
                              onPressed: () => onNavigate('/home/playlists'),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                width: 32,
                                height: 32,
                              ),
                              icon: const Icon(
                                Icons.download_rounded,
                                size: 18,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (playlists.isEmpty)
                        InkWell(
                          onTap: () => onNavigate('/home/playlists'),
                          borderRadius: BorderRadius.circular(XyRadii.medium),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 13,
                              vertical: 14,
                            ),
                            child: Text(
                              '新建或导入第一个歌单',
                              style: TextStyle(
                                fontSize: 12,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        )
                      else
                        for (final playlist in playlists)
                          _PlaylistSidebarTile(
                            playlist: playlist,
                            selected:
                                currentPath == '/home/playlists/${playlist.id}',
                            onTap: () =>
                                onNavigate('/home/playlists/${playlist.id}'),
                          ),
                    ],
                  ],
                ),
              ),
              if (showSettings || showDownloads) ...[
                Divider(
                  height: 1,
                  color: dark ? XyColors.darkBorder : XyColors.lightBorder,
                ),
                if (showDownloads)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 7, 12, 0),
                    child: _SidebarTile(
                      destination: _sidebarDestinations[kSidebarDownloads]!,
                      selected: currentPath == '/settings/downloads',
                      onTap: () => onNavigate('/settings/downloads'),
                    ),
                  ),
                if (showSettings)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 9),
                    child: _SidebarTile(
                      destination: _sidebarDestinations[kSidebarSettings]!,
                      selected: currentPath == '/settings',
                      onTap: () => onNavigate('/settings'),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SidebarDestination {
  const _SidebarDestination(this.label, this.icon, this.path);

  final String label;
  final IconData icon;
  final String path;
}

class _SidebarTile extends StatelessWidget {
  const _SidebarTile({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final _SidebarDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: selected
            ? theme.colorScheme.onSurface.withValues(alpha: 0.09)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(XyRadii.small),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(XyRadii.small),
          child: SizedBox(
            height: 44,
            child: Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  width: 3,
                  height: selected ? 22 : 0,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 11),
                Icon(
                  destination.icon,
                  size: 19,
                  color: selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Text(
                  destination.label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 横屏常驻侧边栏（参考 XianYu-Music-Mobile）：内缘拖动可自由调整宽度，
/// 缩窄到阈值以下仅显示图标；双击把手可在「仅图标 / 展开」两档间切换。
/// 宽度持久化在设置里；拖动期间用本地 setState 保证跟手，松手才落盘。
class XyLandscapeSidebar extends ConsumerStatefulWidget {
  const XyLandscapeSidebar({
    super.key,
    required this.currentPath,
    required this.onNavigate,
    this.onRight = false,
  });

  final String currentPath;
  final ValueChanged<String> onNavigate;
  final bool onRight;

  @override
  ConsumerState<XyLandscapeSidebar> createState() => _XyLandscapeSidebarState();
}

class _XyLandscapeSidebarState extends ConsumerState<XyLandscapeSidebar> {
  static const double _minWidth = 60;
  static const double _maxWidth = 420;
  static const double _iconOnlyBelow = 120;
  static const double _handleWidth = 12;

  double? _dragWidth;
  bool _dragging = false;
  bool _hoveringHandle = false;

  bool _selected(String path) => _destinationSelected(widget.currentPath, path);

  double _maxAllowed(Size viewport) =>
      (viewport.width * 0.5).clamp(_minWidth, _maxWidth);

  void _onDragUpdate(DragUpdateDetails details) {
    final viewport = MediaQuery.sizeOf(context);
    final base =
        _dragWidth ??
        ref.read(settingsProvider).valueOrNull?.landscapeSidebarWidth ??
        176.0;
    // 右侧栏的把手在左缘：向左拖（dx < 0）才是加宽。
    final delta = widget.onRight ? -details.delta.dx : details.delta.dx;
    setState(() {
      _dragWidth = (base + delta).clamp(_minWidth, _maxAllowed(viewport));
    });
  }

  Future<void> _onDragEnd(DragEndDetails details) async {
    final width = _dragWidth;
    if (width == null) return;
    await ref.read(settingsProvider.notifier).setLandscapeSidebarWidth(width);
    // 保留 _dragWidth 作为后续拖动基准：设置是异步落盘的。
  }

  Future<void> _togglePinnedWidth() async {
    const expanded = 176.0;
    const collapsed = 84.0;
    final base =
        _dragWidth ??
        ref.read(settingsProvider).valueOrNull?.landscapeSidebarWidth ??
        expanded;
    final next = base >= _iconOnlyBelow ? collapsed : expanded;
    setState(() => _dragWidth = next);
    await ref.read(settingsProvider.notifier).setLandscapeSidebarWidth(next);
  }

  Widget _buildHeader(bool iconOnly) {
    final icon = Container(
      width: 32,
      height: 32,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(9),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.asset(
          'assets/icon/app_icon.png',
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
      ),
    );
    if (iconOnly) {
      return SizedBox(height: 62, child: Center(child: icon));
    }
    return SizedBox(
      height: 62,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        child: Row(
          children: [
            icon,
            const SizedBox(width: 7),
            const Expanded(
              child: Text(
                'XY Music',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHandle(ThemeData theme, double width) {
    final dark = theme.brightness == Brightness.dark;
    final active = _dragging || _hoveringHandle;
    return GestureDetector(
      onHorizontalDragStart: (_) => setState(() => _dragging = true),
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      onHorizontalDragCancel: () => setState(() => _dragging = false),
      onDoubleTap: _togglePinnedWidth,
      behavior: HitTestBehavior.opaque,
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeLeftRight,
        onEnter: (_) => setState(() => _hoveringHandle = true),
        onExit: (_) => setState(() => _hoveringHandle = false),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: _handleWidth,
              color: active
                  ? theme.colorScheme.primary.withValues(alpha: 0.16)
                  : Colors.transparent,
            ),
            Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: 4,
                height: 38,
                decoration: BoxDecoration(
                  color: active
                      ? theme.colorScheme.primary
                      : (dark ? XyColors.darkBorder : XyColors.lightBorder),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            if (_dragging)
              Positioned(
                top: 12,
                left: _handleWidth / 2 - 26,
                child: IgnorePointer(
                  child: Container(
                    width: 52,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.inverseSurface,
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.28),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: Text(
                      '${width.round()}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.onInverseSurface,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final viewport = MediaQuery.sizeOf(context);
    final persisted = ref.watch(
      settingsProvider.select(
        (s) => s.valueOrNull?.landscapeSidebarWidth ?? 176.0,
      ),
    );
    final width = (_dragWidth ?? persisted).clamp(
      _minWidth,
      _maxAllowed(viewport),
    );
    final iconOnly = width < _iconOnlyBelow;

    final settings = ref.watch(settingsProvider).valueOrNull;
    final hiddenItems =
        settings?.sidebarHiddenItems.toSet() ?? const <String>{};
    final showSettings = !hiddenItems.contains(kSidebarSettings);
    final showDownloads = !hiddenItems.contains(kSidebarDownloads);
    final primaryItems =
        normalizeSidebarItemOrder(
              settings?.sidebarItemOrder ?? kDefaultSidebarItemOrder,
            )
            .where(
              (id) =>
                  id != kSidebarSettings &&
                  id != kSidebarDownloads &&
                  !hiddenItems.contains(id),
            )
            .map((id) => _sidebarDestinations[id])
            .whereType<_SidebarDestination>()
            .toList();

    final borderColor = dark ? XyColors.darkBorder : XyColors.lightBorder;
    final sidebar = SizedBox(
      width: width,
      child: XyAppBackground(
        imagePath: settings?.customBackgroundPath ?? '',
        blur: settings?.customBackgroundBlur ?? 18,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withValues(
              alpha: dark ? 0.9 : 0.97,
            ),
            border: Border(
              left: widget.onRight
                  ? BorderSide(color: borderColor)
                  : BorderSide.none,
              right: widget.onRight
                  ? BorderSide.none
                  : BorderSide(color: borderColor),
            ),
          ),
          child: SafeArea(
            left: !widget.onRight,
            right: widget.onRight,
            child: Column(
              children: [
                _buildHeader(iconOnly),
                Divider(height: 1, color: borderColor),
                Expanded(
                  child: ListView(
                    padding: EdgeInsets.fromLTRB(
                      iconOnly ? 5 : 10,
                      10,
                      iconOnly ? 5 : 6,
                      12,
                    ),
                    children: [
                      for (final item in primaryItems)
                        _LandscapeSidebarTile(
                          destination: item,
                          selected: _selected(item.path),
                          onTap: () => widget.onNavigate(item.path),
                          iconOnly: iconOnly,
                        ),
                    ],
                  ),
                ),
                if (showSettings || showDownloads) ...[
                  Divider(height: 1, color: borderColor),
                  if (showDownloads)
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        iconOnly ? 5 : 12,
                        7,
                        iconOnly ? 5 : 12,
                        0,
                      ),
                      child: _LandscapeSidebarTile(
                        destination: _sidebarDestinations[kSidebarDownloads]!,
                        selected: _selected('/settings/downloads'),
                        onTap: () => widget.onNavigate('/settings/downloads'),
                        iconOnly: iconOnly,
                      ),
                    ),
                  if (showSettings)
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        iconOnly ? 5 : 12,
                        7,
                        iconOnly ? 5 : 12,
                        9,
                      ),
                      child: _LandscapeSidebarTile(
                        destination: _sidebarDestinations[kSidebarSettings]!,
                        selected: _selected('/settings'),
                        onTap: () => widget.onNavigate('/settings'),
                        iconOnly: iconOnly,
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );

    final handle = _buildHandle(theme, width);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.onRight) handle,
        sidebar,
        if (!widget.onRight) handle,
      ],
    );
  }
}

/// 横屏侧栏条目：宽档与抽屉条目同款（文字可截断），窄档仅居中图标。
class _LandscapeSidebarTile extends StatelessWidget {
  const _LandscapeSidebarTile({
    required this.destination,
    required this.selected,
    required this.onTap,
    required this.iconOnly,
  });

  final _SidebarDestination destination;
  final bool selected;
  final bool iconOnly;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (iconOnly) {
      return Tooltip(
        message: destination.label,
        waitDuration: const Duration(milliseconds: 350),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Material(
            color: selected
                ? theme.colorScheme.primary.withValues(alpha: 0.14)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(XyRadii.medium),
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(XyRadii.medium),
              child: SizedBox(
                height: 42,
                child: Center(
                  child: Icon(
                    destination.icon,
                    size: 20,
                    color: selected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: selected
            ? theme.colorScheme.onSurface.withValues(alpha: 0.09)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(XyRadii.small),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(XyRadii.small),
          child: SizedBox(
            height: 44,
            child: Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  width: 3,
                  height: selected ? 22 : 0,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 11),
                Icon(
                  destination.icon,
                  size: 19,
                  color: selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    destination.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PlaylistSidebarTile extends StatelessWidget {
  const _PlaylistSidebarTile({
    required this.playlist,
    required this.selected,
    required this.onTap,
  });

  final MobilePlaylist playlist;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: selected
          ? theme.colorScheme.onSurface.withValues(alpha: 0.09)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(XyRadii.small),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(XyRadii.small),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(
                  Icons.music_note_rounded,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      playlist.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${playlist.songPaths.length} 首',
                      style: TextStyle(
                        fontSize: 10,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
