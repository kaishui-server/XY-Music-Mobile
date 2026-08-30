import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
