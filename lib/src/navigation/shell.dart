import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../player/player_provider.dart';
import '../player/batch_task_store.dart';
import '../core/settings.dart';
import '../ui/xy_theme.dart';
import '../ui/xy_surface.dart';
import '../widgets/mini_player_bar.dart';
import '../widgets/top_notice.dart';
import 'animated_branch_container.dart';
import 'animated_page_route.dart';
import 'player_sheet_morph.dart';
import 'sidebar_controller.dart';

int? _activeRelinkProposalId;

/// 是否存在进行中（运行 / 已暂停）的批量任务：侧栏「任务管理」据此显示
/// 「进行中」角标。
final _hasActiveBatchTaskProvider = Provider<bool>(
  (ref) => ref.watch(
    batchTaskProvider.select((tasks) => tasks.any((task) => task.isActive)),
  ),
);

/// 侧边栏与自定义底栏共用的目的地映射（id → 名称/图标/路由）。
const _sidebarDestinations = <String, _SidebarDestination>{
  kSidebarHome: _SidebarDestination('首页', Icons.home_outlined, '/home'),
  kSidebarExplore: _SidebarDestination(
    '探索',
    Icons.explore_outlined,
    '/home/explore',
  ),
  kSidebarMusicLibrary: _SidebarDestination(
    '音乐库',
    Icons.library_music_outlined,
    '/music-library',
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
  kSidebarDownloads: _SidebarDestination(
    '任务管理',
    Icons.checklist_rounded,
    '/settings/tasks',
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
  // 子路由有独立入口时（如 /settings/tasks 相对 /settings）只高亮
  // 更长前缀的那个入口，避免“任务管理”与“设置”同时点亮。
  for (final destination in _sidebarDestinations.values) {
    final other = destination.path.split('?').first;
    if (other.length > normalized.length &&
        (currentPath == other || currentPath.startsWith('$other/'))) {
      return false;
    }
  }
  return true;
}

/// 分支切换方向追踪：+1 新页从右侧进入，-1 从左侧进入。
///
/// 路由分支顺序（首页/音乐库/音效/设置）与用户可见的目的地顺序
/// （可自定义的底栏/侧栏）并不一致，且「探索」是首页分支内的子路由；
/// 若按分支下标差推断方向，沿底栏顺序前进的切换会左右不定。这里改
/// 为按可见顺序比较新旧页面的目的地位置判定方向，供
/// AnimatedBranchContainer 在分支切换时消费。
final branchSwitchDirection = BranchSwitchDirectionTracker();

class BranchSwitchDirectionTracker {
  int value = 1;
  String? _lastPath;
  int _lastBranchIndex = 0;

  /// 每次导航（AppShell 随路由状态重建）时调用；同路径/同分支的重建
  /// 不改变方向，仅持续跟踪最新路径供下次比较。
  void update(
    String currentPath,
    int currentBranchIndex,
    List<String> visiblePaths,
  ) {
    final lastPath = _lastPath;
    final lastBranchIndex = _lastBranchIndex;
    _lastPath = currentPath;
    _lastBranchIndex = currentBranchIndex;
    if (lastPath == null || currentPath == lastPath) return;
    if (currentBranchIndex == lastBranchIndex) return;
    final from = _visiblePosition(lastPath, visiblePaths);
    final to = _visiblePosition(currentPath, visiblePaths);
    if (from >= 0 && to >= 0 && from != to) {
      value = to > from ? 1 : -1;
    } else {
      // 新旧页面无法定位到可见目的地（如歌单详情页）时，退回分支
      // 下标顺序，保持旧行为。
      value = currentBranchIndex > lastBranchIndex ? 1 : -1;
    }
  }

  static int _visiblePosition(String path, List<String> visiblePaths) {
    for (var index = 0; index < visiblePaths.length; index++) {
      if (_destinationSelected(path, visiblePaths[index])) return index;
    }
    return -1;
  }
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
    // 队列中存在「所属插件已停用」的残留歌曲：一次性提示，允许直接清理。
    ref.listen<ResidualPluginQueueNotice?>(residualPluginQueueNoticeProvider, (
      previous,
      next,
    ) {
      if (next == null) return;
      ref.read(residualPluginQueueNoticeProvider.notifier).state = null;
      final messengerContext = appScaffoldKey.currentContext ?? context;
      XyNotice.show(
        messengerContext,
        message:
            '播放队列中有 ${next.songCount} 首来自已停用插件'
            '「${next.pluginNames}」的歌曲，可一键清理',
        type: XyNoticeType.warning,
        duration: const Duration(seconds: 8),
        actionLabel: '清理',
        onAction: () async {
          final removed = await ref
              .read(playerProvider.notifier)
              .removeResidualPluginSongs(next.pluginIds);
          final noticeContext = appScaffoldKey.currentContext;
          if (noticeContext == null) return;
          XyNotice.show(
            noticeContext,
            message: removed > 0 ? '已清理 $removed 首残留歌曲' : '没有可清理的残留歌曲',
            type: removed > 0 ? XyNoticeType.success : XyNoticeType.info,
          );
        },
      );
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
        bottomBarItemIds.length >= 2 &&
        !currentPath.startsWith('/cloud-');
    // 悬浮元素（底栏+迷你播放栏）在系统安全区之上占用的总高度，注入
    // MediaQuery.padding.bottom：页面 SafeArea 或显式读取该值即可让
    // 底部内容不被悬浮元素遮挡（修复插件管理/本地音乐等页面被盖住）。
    final extraBottomPadding =
        (bottomBarVisible ? kBottomBarHeight + kBottomBarBottomGap * 2 : 0.0) +
        (miniPlayerVisible
            ? kMiniPlayerHeight +
                  (bottomBarVisible ? 0.0 : kMiniPlayerBottomGap)
            : 0.0);

    // 分支切换方向：按用户可见的目的地顺序（底栏条目在前，其余按侧栏
    // 顺序）跟踪导航轨迹。AppShell 每次导航都先于分支容器重建，此处
    // 更新后由路由层在分支切换时读取。
    final sidebarOrderIds = normalizeSidebarItemOrder(
      shellSettings?.sidebarItemOrder ?? kDefaultSidebarItemOrder,
    );
    final visiblePaths = <String>[
      for (final id in [
        if (bottomBarVisible) ...bottomBarItemIds,
        ...sidebarOrderIds.where(
          (id) => !bottomBarVisible || !bottomBarItemIds.contains(id),
        ),
      ])
        if (_sidebarDestinations.containsKey(id))
          _sidebarDestinations[id]!.path,
    ];
    branchSwitchDirection.update(
      currentPath,
      navigationShell.currentIndex,
      visiblePaths,
    );

    // 横滑切页：把可见目的地顺序映射成分支下标序列，供分支容器判断拖动
    // 方向的相邻页。仅在一级页面根部启用——进入二级页（歌单详情、设置
    // 子页等）后让位给页面自身手势与系统返回。
    final branchPaths = <String?>[
      for (final branch in navigationShell.route.branches)
        branch.routes.isNotEmpty && branch.routes.first is GoRoute
            ? (branch.routes.first as GoRoute).path
            : null,
    ];
    final swipeOrder = branchSwipeOrderFromPaths(
      visiblePaths: visiblePaths,
      branchPaths: branchPaths,
      currentIndex: navigationShell.currentIndex,
    );
    // 仅在一级页面启用：当前路由等于某个分支根，或等于某个可见目的地
    // （侧栏一级入口，如插件管理 /settings/plugins）。进入二级页（歌单
    // 详情、设置子页等）后让位给页面自身手势与系统返回。
    final swipeTopLevel =
        branchPaths.contains(currentPath) ||
        visiblePaths.any((path) => path.split('?').first == currentPath);
    updateBranchSwipe(
      enabled: bottomBarVisible && swipeTopLevel && swipeOrder.length >= 2,
      order: swipeOrder,
    );

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

    final scaffold = Scaffold(
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

    // 系统返回键：仅在「当前分支已无返回栈、根导航也无全屏覆盖页」时
    // 才会落到这里（go_router 的分支内子页弹出、播放页/搜索页等覆盖
    // 页的弹出均在此之前已被处理）。此时不再直接退出软件：侧边栏
    // 一级页面（设置/本地音乐/账号等）先回到首页，
    // 已在首页时按返回才退出软件。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        // 侧边栏打开时返回手势优先收起侧边栏。Drawer 打开时虽然会向
        // 当前路由注册 LocalHistoryEntry（返回键先关抽屉），但该机制
        // 的 popDisposition 会被本 PopScope 的 canPop:false 压制，
        // 返回事件全部落到这里——不手动处理就会直接退出软件。
        final scaffold = appScaffoldKey.currentState;
        if (scaffold != null &&
            (scaffold.isDrawerOpen || scaffold.isEndDrawerOpen)) {
          scaffold.closeDrawer();
          scaffold.closeEndDrawer();
          return;
        }
        if (currentPath == '/home') {
          SystemNavigator.pop();
        } else {
          context.go('/home');
        }
      },
      // 壳层转场冻结门（P0-4 + 转场快照）：
      // 1) 路由落定后整棵停画壳层（P0-4）。播放详情页路由是 opaque:false，
      //    落定（动画完成）后壳层仍在其下每帧参与布局/光栅化，只是画面被
      //    完全盖住——这是低端机上「进出播放详情页卡」的固定损耗。此处把
      //    壳层 Offstage + TickerMode(false)，静止态零绘制开销。
      // 2) 转场未落定期间（morphing），壳层快照冻结（SnapshotWidget）。
      //    形变面板半透明，转场中壳层必须画在面板底下；但壳层在转场中本
      //    就完全静止（二级转场被冻结、迷你播放栏隐藏、Ticker 停转），每帧
      //    仍对整棵壳层 UI 重新光栅化纯属浪费——5632 探针实测 raster 侧
      //    卡顿是 UI 侧 3.6 倍（raster=+231 vs ui=+64 / 30s），worstR 单帧
      //    63ms。SnapshotWidget 在首帧把壳层栅格化为一张纹理，后续帧直接
      //    合成该纹理，每帧成本从「整棵壳层 UI」降到「一张图」。收起动画
      //    开始时 morphing 再次置位，快照重新启用（先画一帧实时再冻结）。
      //    快照遇到不支持的内容（平台视图等）自动回退实时绘制，零风险。
      // 3) 结构恒定：Offstage/TickerMode/SnapshotWidget 三层常驻包装，只
      //    切换布尔值，绝不切换 widget 类型——保证壳层 Element 树不重建，
      //    返回手势、抽屉、各页滚动位置均不受影响。
      child: AnimatedBuilder(
        animation: Listenable.merge([
          xySheetRouteActive,
          xyPlayerSheetMorphing,
        ]),
        builder: (context, _) {
          // 存活守卫：冻结/隐藏只在形变路由真实存在于导航栈时生效。
          // 万一这次展开没成功（push 被拒、竞态、导航器未就绪）而全局
          // 标记又残留下来，这里直接按「未转场」渲染——否则壳层会被
          // 永久快照/Offstage，表现成整页卡死、点不动。
          final sheetAlive = xyPlayerSheetRouteRef?.isActive ?? false;
          final active = sheetAlive && xySheetRouteActive.value;
          return _ShellFreezeGate(
            morphing: active && xyPlayerSheetMorphing.value,
            covered: active && !xyPlayerSheetMorphing.value,
            child: scaffold,
          );
        },
      ),
    );
  }
}

/// 壳层转场冻结门：morphing 时用快照冻结壳层（单纹理合成），covered 时
/// Offstage 停画，其余时间实时绘制。见 [AppShell] build 内的完整说明。
class _ShellFreezeGate extends StatefulWidget {
  const _ShellFreezeGate({
    required this.morphing,
    required this.covered,
    required this.child,
  });

  final bool morphing;
  final bool covered;
  final Widget child;

  @override
  State<_ShellFreezeGate> createState() => _ShellFreezeGateState();
}

class _ShellFreezeGateState extends State<_ShellFreezeGate> {
  late final SnapshotController _snapshotController = SnapshotController(
    allowSnapshotting: widget.morphing,
  );

  @override
  void didUpdateWidget(covariant _ShellFreezeGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.morphing != widget.morphing) {
      _snapshotController.allowSnapshotting = widget.morphing;
    }
  }

  @override
  void dispose() {
    _snapshotController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Offstage(
      offstage: widget.covered,
      child: TickerMode(
        // 转场中壳层完全静止，Ticker 停转避免无意义的帧调度；快照冻结
        // 期间子树也不需要任何动画产出。
        enabled: !widget.covered && !widget.morphing,
        child: SnapshotWidget(
          controller: _snapshotController,
          // permissive：子树含平台视图（如个别设置页的 WebView）时快照
          // 不可用，自动回退实时绘制；normal 模式会直接抛异常，壳层是
          // 全局容器，绝不能用 normal。
          mode: SnapshotMode.permissive,
          child: widget.child,
        ),
      ),
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
    // 底栏容器本体：颜色/描边/投影/内容，与是否挂毛玻璃无关，单独提出，
    // 供下面的条件包装复用同一棵子树（切换毛玻璃开关时不重建内容）。
    final bar = Container(
      height: kBottomBarHeight,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: dark ? .34 : .48),
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
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(XyRadii.large),
      // 【性能】底栏一级分页切换期间临时摘掉毛玻璃：切换时前后两页在全屏
      // 尺寸上交叉淡化，模糊层每帧还要对变化中的整条栏宽背景重新采样，
      // 两项开销叠在同一批帧上正把 raster 线程压爆。切换落定即恢复；
      // 200ms 内只是少一层背景模糊，底色/描边/投影完全不变，观感差别极小。
      child: ValueListenableBuilder<bool>(
        valueListenable: xyBranchSwitchActive,
        builder: (context, switching, child) => switching
            ? child!
            : BackdropFilter.grouped(
                filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                child: child!,
              ),
        child: bar,
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
    path != '/account' &&
    path != '/settings' &&
    !path.startsWith('/settings/') &&
    !path.startsWith('/cloud-');

/// 与电脑端 Sidebar 相同的信息层级，手机端使用抽屉承载。
class XyMobileSidebar extends ConsumerWidget {
  const XyMobileSidebar({
    super.key,
    required this.currentPath,
    required this.onNavigate,
  });

  final String currentPath;
  final ValueChanged<String> onNavigate;

  bool _selected(String path) => _destinationSelected(currentPath, path);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final settings = ref.watch(settingsProvider).valueOrNull;
    final width = MediaQuery.sizeOf(context).width * 0.5;
    final hasActiveTask = ref.watch(_hasActiveBatchTaskProvider);

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

    return Drawer(
      width: width,
      elevation: 0,
      shape: const RoundedRectangleBorder(),
      backgroundColor: Colors.transparent,
      child: XyAppBackground(
        imagePath: settings?.customBackgroundPath ?? '',
        blur: settings?.customBackgroundBlur ?? 18,
        fade: settings?.customBackgroundFade ?? 0,
        fit: settings?.backgroundFitMode ?? BackgroundFitMode.cover,
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
                      selected: currentPath == '/settings/tasks',
                      showRunningBadge: hasActiveTask,
                      onTap: () => onNavigate('/settings/tasks'),
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
    this.showRunningBadge = false,
  });

  final _SidebarDestination destination;
  final bool selected;
  final VoidCallback onTap;

  /// 在文案右上角显示「进行中」角标（仅任务管理且有活动任务时为 true）。
  final bool showRunningBadge;

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
            height: 50,
            child: Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  width: 3,
                  height: selected ? 26 : 0,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 11),
                Icon(
                  destination.icon,
                  size: 22,
                  color: selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      destination.label,
                      style: TextStyle(
                        fontSize: 15.5,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                    if (showRunningBadge) ...[
                      const SizedBox(width: 5),
                      Transform.translate(
                        offset: const Offset(0, -6),
                        child: const _RunningBadge(),
                      ),
                    ],
                  ],
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
    final hasActiveTask = ref.watch(_hasActiveBatchTaskProvider);
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
        fade: settings?.customBackgroundFade ?? 0,
        fit: settings?.backgroundFitMode ?? BackgroundFitMode.cover,
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
                        selected: _selected('/settings/tasks'),
                        onTap: () => widget.onNavigate('/settings/tasks'),
                        iconOnly: iconOnly,
                        showRunningBadge: hasActiveTask,
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

/// 「进行中」角标：任务管理入口文案右上角的小标签，有活动任务时显示。
class _RunningBadge extends StatelessWidget {
  const _RunningBadge();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '进行中',
        style: TextStyle(
          fontSize: 9,
          height: 1.1,
          fontWeight: FontWeight.w700,
          color: scheme.onPrimary,
        ),
      ),
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
    this.showRunningBadge = false,
  });

  final _SidebarDestination destination;
  final bool selected;
  final bool iconOnly;
  final VoidCallback onTap;

  /// 在文案右上角显示「进行中」角标（仅任务管理且有活动任务时为 true）。
  final bool showRunningBadge;

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
                height: 48,
                child: Center(
                  child: Icon(
                    destination.icon,
                    size: 23,
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
            height: 50,
            child: Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  width: 3,
                  height: selected ? 26 : 0,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 11),
                Icon(
                  destination.icon,
                  size: 22,
                  color: selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          destination.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15.5,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                      if (showRunningBadge) ...[
                        const SizedBox(width: 5),
                        Transform.translate(
                          offset: const Offset(0, -6),
                          child: const _RunningBadge(),
                        ),
                      ],
                    ],
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
