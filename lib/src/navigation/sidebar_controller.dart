import 'package:flutter/material.dart';

final appScaffoldKey = GlobalKey<ScaffoldState>();

void openAppSidebar() => appScaffoldKey.currentState?.openDrawer();

/// 一级页面共用的简洁侧栏入口。
class AppSidebarMenuButton extends StatelessWidget {
  const AppSidebarMenuButton({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: '打开侧栏',
      onPressed: openAppSidebar,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 44, height: 44),
      icon: const Icon(Icons.menu_rounded, size: 25),
    );
  }
}
