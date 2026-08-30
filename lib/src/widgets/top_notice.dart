import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

enum XyNoticeType { info, success, warning, error }

/// 全局顶部提示条。使用根 Overlay，确保在抽屉、弹窗和各级路由上都从
/// 窗口顶部出现，而不是跟随当前 Scaffold 落到左下角。
class XyNotice {
  XyNotice._();

  static _NoticeHandle? _current;

  static void show(
    BuildContext context, {
    required String message,
    XyNoticeType type = XyNoticeType.info,
    Duration duration = const Duration(milliseconds: 2600),
    String? actionLabel,
    VoidCallback? onAction,
    bool compact = false,
    bool blur = false,
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null || message.trim().isEmpty) return;

    // 连续提示时直接收起旧条，避免两个提示在顶部叠放；单条提示的正常
    // 生命周期仍完整执行入场与出场动画。
    _current?.dismiss(immediately: true);

    final key = GlobalKey<_TopNoticeOverlayState>();
    late final OverlayEntry entry;
    late final _NoticeHandle handle;
    entry = OverlayEntry(
      builder: (overlayContext) => _TopNoticeOverlay(
        key: key,
        message: message.trim(),
        type: type,
        duration: duration,
        actionLabel: actionLabel,
        onAction: onAction,
        compact: compact,
        blur: blur,
        onDismissed: () {
          if (entry.mounted) entry.remove();
          if (identical(_current, handle)) _current = null;
        },
      ),
    );
    handle = _NoticeHandle(entry: entry, key: key);
    _current = handle;
    overlay.insert(entry);
  }

  static void hide() => _current?.dismiss();
}

class _NoticeHandle {
  const _NoticeHandle({required this.entry, required this.key});

  final OverlayEntry entry;
  final GlobalKey<_TopNoticeOverlayState> key;

  void dismiss({bool immediately = false}) {
    final state = key.currentState;
    if (!immediately && state != null) {
      unawaited(state.dismiss());
      return;
    }
    if (entry.mounted) entry.remove();
  }
}

class _TopNoticeOverlay extends StatefulWidget {
  const _TopNoticeOverlay({
    super.key,
    required this.message,
    required this.type,
    required this.duration,
    required this.onDismissed,
    this.actionLabel,
    this.onAction,
    this.compact = false,
    this.blur = false,
  });

  final String message;
  final XyNoticeType type;
  final Duration duration;
  final VoidCallback onDismissed;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool compact;
  final bool blur;

  @override
  State<_TopNoticeOverlay> createState() => _TopNoticeOverlayState();
}

class _TopNoticeOverlayState extends State<_TopNoticeOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<Offset> _offset;
  Timer? _timer;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
      reverseDuration: const Duration(milliseconds: 210),
    );
    final curved = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _opacity = curved;
    _offset = Tween<Offset>(
      begin: const Offset(0, -0.45),
      end: Offset.zero,
    ).animate(curved);
    unawaited(_controller.forward());
    _timer = Timer(widget.duration, dismiss);
  }

  Future<void> dismiss() async {
    if (_dismissing || !mounted) return;
    _dismissing = true;
    _timer?.cancel();
    await _controller.reverse();
    if (mounted) widget.onDismissed();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = _noticeColors(theme.colorScheme, widget.type);
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        minimum: const EdgeInsets.fromLTRB(14, 12, 14, 0),
        child: Align(
          alignment: Alignment.topCenter,
          child: FadeTransition(
            key: const ValueKey('xy-top-notice-fade'),
            opacity: _opacity,
            child: SlideTransition(
              position: _offset,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                // BackdropFilter 必须被局部裁剪，否则其滤镜区域会扩展到
                // Overlay 的整块画布，导致提示条之外的页面也被模糊。
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: BackdropFilter(
                    filter: widget.blur
                        ? ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12)
                        : ui.ImageFilter.blur(sigmaX: 0, sigmaY: 0),
                    child: Material(
                      key: const ValueKey('xy-top-notice'),
                      color: widget.blur
                          ? colors.background.withValues(alpha: .64)
                          : colors.background,
                      elevation: 10,
                      shadowColor: Colors.black.withValues(alpha: 0.24),
                      borderRadius: BorderRadius.circular(16),
                      clipBehavior: Clip.antiAlias,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: colors.accent.withValues(alpha: 0.28),
                          ),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Padding(
                          padding: widget.compact
                              ? const EdgeInsets.fromLTRB(12, 5, 4, 5)
                              : const EdgeInsets.fromLTRB(14, 10, 6, 10),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                colors.icon,
                                size: widget.compact ? 18 : 20,
                                color: colors.accent,
                              ),
                              SizedBox(width: widget.compact ? 8 : 10),
                              Flexible(
                                child: Text(
                                  widget.message,
                                  maxLines: widget.compact ? 2 : 4,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: colors.foreground,
                                    fontSize: widget.compact ? 12 : 13,
                                    fontWeight: FontWeight.w600,
                                    height: 1.35,
                                  ),
                                ),
                              ),
                              if (widget.actionLabel != null &&
                                  widget.onAction != null) ...[
                                const SizedBox(width: 8),
                                TextButton(
                                  onPressed: () {
                                    widget.onAction!();
                                    unawaited(dismiss());
                                  },
                                  style: TextButton.styleFrom(
                                    foregroundColor: colors.accent,
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  child: Text(widget.actionLabel!),
                                ),
                              ],
                              IconButton(
                                tooltip: '关闭提示',
                                onPressed: dismiss,
                                visualDensity: VisualDensity.compact,
                                iconSize: widget.compact ? 16 : 18,
                                color: colors.foreground.withValues(
                                  alpha: 0.68,
                                ),
                                icon: const Icon(Icons.close_rounded),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

({Color background, Color foreground, Color accent, IconData icon})
_noticeColors(ColorScheme scheme, XyNoticeType type) {
  final dark = scheme.brightness == Brightness.dark;
  return switch (type) {
    XyNoticeType.success => (
      background: dark ? const Color(0xFF14251C) : const Color(0xFFF0FAF3),
      foreground: dark ? const Color(0xFFE4F7EA) : const Color(0xFF163D23),
      accent: const Color(0xFF36A85F),
      icon: Icons.check_circle_outline_rounded,
    ),
    XyNoticeType.warning => (
      background: dark ? const Color(0xFF2A2111) : const Color(0xFFFFF8E8),
      foreground: dark ? const Color(0xFFFFEDC0) : const Color(0xFF553A00),
      accent: const Color(0xFFE49A18),
      icon: Icons.warning_amber_rounded,
    ),
    XyNoticeType.error => (
      background: dark ? const Color(0xFF2A1719) : const Color(0xFFFFF1F2),
      foreground: dark ? const Color(0xFFFFE5E7) : const Color(0xFF5D171D),
      accent: scheme.error,
      icon: Icons.error_outline_rounded,
    ),
    XyNoticeType.info => (
      background: dark ? const Color(0xFF18232E) : const Color(0xFFF1F7FD),
      foreground: dark ? const Color(0xFFE5F1FC) : const Color(0xFF173B5C),
      accent: scheme.primary,
      icon: Icons.info_outline_rounded,
    ),
  };
}
