// 网盘模块 UI 适配层（XY 移植版）。
//
// 弦予页面依赖 app_colors / i18n / glass 组件 / app_toast / predictive
// 路由等，XY 无这些模块。此文件提供同签名替代实现，页面代码仅需替换
// import 即可编译运行。

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 文案占位符替换：`tr('尚未绑定{name}', {'name': x})` → `cloudT(...)`。
String cloudT(String s, [Map<String, String>? args]) {
  if (args == null || args.isEmpty) return s;
  var out = s;
  args.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// 页面背景（XY 直接使用主题 scaffold 背景）。
Color appScaffoldBackground(BuildContext context, WidgetRef ref) =>
    Theme.of(context).scaffoldBackgroundColor;

/// 毛玻璃卡片替代：半透明 surface 圆角容器。
Widget frostedCardSurface({
  required BuildContext context,
  required WidgetRef ref,
  double radius = 16,
  required Widget child,
}) {
  final scheme = Theme.of(context).colorScheme;
  return Container(
    decoration: BoxDecoration(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(
        color: scheme.onSurface.withValues(alpha: 0.06),
        width: 0.5,
      ),
    ),
    clipBehavior: Clip.antiAlias,
    child: child,
  );
}

/// Toast 替代：ScaffoldMessenger SnackBar。
void showXianYuToast(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(milliseconds: 1600),
    ),
  );
}

/// 顶部栏替代：普通 Material AppBar 容器，提供与弦予一致的 height()。
class GlassTopBar extends StatelessWidget implements PreferredSizeWidget {
  const GlassTopBar({super.key, this.leading, this.title, this.actions});

  final Widget? leading;
  final Widget? title;
  final List<Widget>? actions;

  static double height(BuildContext context) =>
      kToolbarHeight + MediaQuery.paddingOf(context).top;

  @override
  Size get preferredSize => Size.fromHeight(
        kToolbarHeight + MediaQueryData.fromView(
          WidgetsBinding.instance.platformDispatcher.views.first,
        ).padding.top,
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface.withValues(alpha: 0.85),
      elevation: 0,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: kToolbarHeight,
          child: Row(
            children: [
              if (leading != null) leading!,
              Expanded(
                child: title != null
                    ? DefaultTextStyle(
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                        child: title!,
                      )
                    : const SizedBox.shrink(),
              ),
              if (actions != null) ...actions!,
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}

/// 预测式对话框替代：普通 showDialog。
Future<T?> showPredictiveDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: builder,
  );
}

/// 按压缩放包装（简化版）。
class PressableScale extends StatefulWidget {
  const PressableScale({
    super.key,
    required this.child,
    this.pressScale = 0.95,
    this.onTap,
  });

  final Widget child;
  final double pressScale;
  final VoidCallback? onTap;

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap?.call();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? widget.pressScale : 1.0,
        duration: const Duration(milliseconds: 90),
        child: widget.child,
      ),
    );
  }
}

/// 日志替代（弦予 AppLog 静态方法签名兼容）。
class AppLog {
  static void debug(String tag, String message) =>
      debugPrint('[$tag] $message');
  static void warn(String tag, String message) =>
      debugPrint('[cloud][$tag] $message');
}
