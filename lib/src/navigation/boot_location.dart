import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/settings.dart';

/// 启动落点表：侧栏 / 自定义底栏目的地 id → 该入口对应的一级路由。
///
/// 与 [shell.dart] 中 `_sidebarDestinations` 的 id→路径保持一致，但这里
/// 用的是**不带查询参数的干净路径**：启动落点要写进 `GoRouter` 的
/// `initialLocation`，带上 `?from=sidebar` 这类来源标记会让首屏表现出
/// 「从侧栏点进来」的语义（例如多显示一个侧栏按钮）。
const Map<String, String> kBootLocationPaths = <String, String>{
  kSidebarHome: '/home',
  kSidebarExplore: '/home/explore',
  kSidebarMusicLibrary: '/music-library',
  kSidebarPlugins: '/settings/plugins',
  kSidebarAccount: '/account',
  kSidebarRecognize: '/home/recognize',
  kSidebarDownloads: '/settings/tasks',
  kSidebarSettings: '/settings',
};

/// 兜底落点：任何一步算不出来（首次安装、脏数据、预热失败）都回首页，
/// 与改造前的行为完全一致。
const String kDefaultBootLocation = '/home';

/// 按「用户实际看到的顺序」展开一级入口 id 列表。
///
/// 顺序口径与 [AppShell] 里 `visiblePaths` 的构造完全一致：自定义底栏
/// 启用且有至少两个条目时，底栏条目排在最前（底栏本身就是用户最先看到
/// 的入口），其余按侧栏排序补齐。不一致会导致「排序第一项」和「启动页」
/// 对不上，用户会认为排序没生效。
List<String> bootVisibleItemIds({
  required List<String> sidebarItemOrder,
  required List<String> bottomBarItemIds,
  required bool bottomBarEnabled,
}) {
  final order = normalizeSidebarItemOrder(sidebarItemOrder);
  final bottomIds = normalizeBottomBarItemIds(bottomBarItemIds);
  final bottomActive = bottomBarEnabled && bottomIds.length >= 2;
  return <String>[
    if (bottomActive) ...bottomIds,
    ...order.where((id) => !bottomActive || !bottomIds.contains(id)),
  ];
}

/// 由可见入口顺序推出启动落点路径。
///
/// 跳过两类 id：
/// - 没有对应路由的未知 id（脏数据，理论上 [normalizeSidebarItemOrder]
///   已经过滤，这里再兜一层）；
/// - 在侧栏里被隐藏、且不在底栏展示的入口——用户明摆着不想看到它，
///   启动直接落到这一页会找不到回去的入口。
///
/// [sidebarHiddenItems] 里的条目如果同时出现在底栏，则仍然算可见。
String bootLocationFor({
  required List<String> sidebarItemOrder,
  required List<String> bottomBarItemIds,
  required List<String> sidebarHiddenItems,
  required bool bottomBarEnabled,
}) {
  final bottomIds = normalizeBottomBarItemIds(bottomBarItemIds);
  final hidden = sidebarHiddenItems.toSet();
  for (final id in bootVisibleItemIds(
    sidebarItemOrder: sidebarItemOrder,
    bottomBarItemIds: bottomIds,
    bottomBarEnabled: bottomBarEnabled,
  )) {
    final path = kBootLocationPaths[id];
    if (path == null) continue;
    if (hidden.contains(id) && !bottomIds.contains(id)) continue;
    return path;
  }
  return kDefaultBootLocation;
}

/// 启动预热的 SharedPreferences 快照。
///
/// `GoRouter.initialLocation` 只能是同步值，而 [settingsProvider] 是异步
/// `AsyncNotifier`——首帧前拿不到用户排序。若等设置加载完再跳转，用户会
/// 先看到首页闪一下，等于没修。因此在 `runApp` 之前把偏好同步读出来缓存
/// 在这里，供 [resolveBootLocation] 同步取用。
SharedPreferences? bootPrefsSnapshot;

/// 首帧前预热偏好快照；重复调用无副作用。
Future<void> warmUpBootPrefs() async {
  if (bootPrefsSnapshot != null) return;
  try {
    bootPrefsSnapshot = await SharedPreferences.getInstance();
  } catch (error) {
    // 预热失败不是致命错误：落点退回首页，其余设置仍由 settingsProvider
    // 自己的异步读取负责，不能因为这里失败挡住启动。
    debugPrint('启动落点偏好预热失败，回退默认首页：$error');
    bootPrefsSnapshot = null;
  }
}

/// 同步解析启动落点；快照尚未就绪时返回默认首页。
String resolveBootLocation() {
  final prefs = bootPrefsSnapshot;
  if (prefs == null) return kDefaultBootLocation;
  try {
    return bootLocationFor(
      sidebarItemOrder:
          prefs.getStringList('sidebarItemOrder') ?? kDefaultSidebarItemOrder,
      bottomBarItemIds: prefs.getStringList('bottomBarItemIds') ?? const [],
      sidebarHiddenItems:
          prefs.getStringList('sidebarHiddenItems') ?? const [],
      bottomBarEnabled: prefs.getBool('bottomBarEnabled') ?? false,
    );
  } catch (error) {
    debugPrint('启动落点解析失败，回退默认首页：$error');
    return kDefaultBootLocation;
  }
}
