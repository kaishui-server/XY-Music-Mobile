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
  kSidebarExplore: _SidebarDestination('探索', Icons.explore_outlined, '/home/explore'),
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
  kSidebarLibrary: _SidebarDestination(
    '音乐库',
    Icons.library_music_outlined,
    '/settings/library',
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
  kSidebarSettings: _SidebarDestination('设置', Icons.settings_outlined, '/settings'),
};

/// 目的地是否对应当前路由（忽略查询参数，支持子路由高亮）。
bool _destinationSelected(String currentPath, String path) {
  final normalized = path.split('?').first;
  if (normalized == '/home') return currentPath == '/home';
  return currentPath == normalized || currentPath.startsWith('$normalized/');
}

/// 自定义底栏的高度与悬浮间距（迷你播放栏据此让位）。
const kBottomBarHeight = 60.0;
const kBottomBarBottomGap = 12.0;

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
    final sidebarOnRight =
        ref.watch(settingsProvider).valueOrNull?.sidebarPosition ==
        SidebarPosition.right;
    final shellSettings = ref.watch(settingsProvider).valueOrNull;
    final bottomBarItemIds = shellSettings?.bottomBarItemIds ?? const <String>[];
    final bottomBarVisible =
        (shellSettings?.bottomBarEnabled ?? false) &&
        bottomBarItemIds.length >= 2;
    // 底栏可见时抬高页面安全区底部内边距，列表内容不被悬浮底栏遮挡。
    final extraBottomPadding = bottomBarVisible
        ? kBottomBarHeight + kBottomBarBottomGap * 2
        : 0.0;

    void navigate(String path) {
      Navigator.of(appScaffoldKey.currentContext!).pop();
      Future<void>.microtask(() async {
        if (context.mounted) context.go(path);
      });
    }

    return Scaffold(
      key: appScaffoldKey,
      extendBody: true,
      drawerScrimColor: Colors.black.withValues(alpha: 0.58),
      drawerEdgeDragWidth: MediaQuery.sizeOf(context).width * 0.16,
      drawer: sidebarOnRight
          ? null
          : XyMobileSidebar(currentPath: currentPath, onNavigate: navigate),
      endDrawer: sidebarOnRight
          ? XyMobileSidebar(currentPath: currentPath, onNavigate: navigate)
          : null,
      body: Stack(
        children: [
          MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: MediaQuery.of(context).padding.copyWith(
                bottom: safeBottom + extraBottomPadding,
              ),
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
              bottom: safeBottom +
                  (bottomBarVisible
                      ? kBottomBarHeight + kBottomBarBottomGap * 2
                      : 20),
              child: const MiniPlayerBar(),
            ),
        ],
      ),
    );
  }
}

/// 自定义底栏：与迷你播放栏同款的毛玻璃悬浮条，展示用户挑选的目的地。
/// 默认关闭，在「设置-布局」完成条目自定义（≥2 项）后自动开启。
class XyBottomBar extends StatelessWidget {
  const XyBottomBar({
    super.key,
    required this.itemIds,
    required this.currentPath,
  });

  final List<String> itemIds;
  final String currentPath;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
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
    required this.onTap,
  });

  final _SidebarDestination destination;
  final bool selected;
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
          Icon(destination.icon, size: 22, color: color),
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
    final primaryItems =
        normalizeSidebarItemOrder(
              settings?.sidebarItemOrder ?? kDefaultSidebarItemOrder,
            )
            .where((id) => id != kSidebarSettings && !hiddenItems.contains(id))
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
              if (showSettings) ...[
                Divider(
                  height: 1,
                  color: dark ? XyColors.darkBorder : XyColors.lightBorder,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 7, 12, 0),
                  child: _SidebarTile(
                    destination: const _SidebarDestination(
                      '下载管理',
                      Icons.download_rounded,
                      '/settings/downloads',
                    ),
                    selected: currentPath == '/settings/downloads',
                    onTap: () => onNavigate('/settings/downloads'),
                  ),
                ),
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
