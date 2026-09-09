import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/settings.dart';

final appScaffoldKey = GlobalKey<ScaffoldState>();

void openAppSidebar({bool end = false}) {
  final state = appScaffoldKey.currentState;
  if (end) {
    state?.openEndDrawer();
  } else {
    state?.openDrawer();
  }
}

/// 侧边栏条目导航：抽屉打开时先收起抽屉，等关闭动画结束后再切换页面，
/// 避免抽屉收起与页面切换动画同时进行造成“页面叠加”的观感。
///
/// 注意：scaffoldKey 是 [GlobalKey<ScaffoldState>]，必须直接取
/// currentState 使用；[Scaffold.of] 以 Scaffold 自身 context 调用会因
/// 查不到祖先 Scaffold 而抛异常，导致条目点击无任何反应。关闭抽屉也
/// 必须用 closeDrawer/closeEndDrawer——Navigator.pop 弹掉的是当前页面
/// 路由而不是抽屉。
void navigateFromSidebar(
  BuildContext context,
  GlobalKey<ScaffoldState> scaffoldKey,
  String path,
) {
  final scaffold = scaffoldKey.currentState;
  if (scaffold != null &&
      (scaffold.isDrawerOpen || scaffold.isEndDrawerOpen)) {
    scaffold.closeDrawer();
    scaffold.closeEndDrawer();
    Future<void>.delayed(const Duration(milliseconds: 260), () {
      if (context.mounted) context.go(path);
    });
    return;
  }
  context.go(path);
}

/// 一级页面共用的简洁侧栏入口。
class AppSidebarMenuButton extends ConsumerWidget {
  const AppSidebarMenuButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position = ref.watch(
      settingsProvider.select(
        (value) => value.valueOrNull?.sidebarPosition ?? SidebarPosition.left,
      ),
    );
    return IconButton(
      tooltip: '打开侧栏',
      onPressed: () => openAppSidebar(end: position == SidebarPosition.right),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 44, height: 44),
      icon: const Icon(Icons.menu_rounded, size: 25),
    );
  }
}
