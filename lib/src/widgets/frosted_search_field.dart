import 'dart:ui';

import 'package:flutter/material.dart';

/// 全局通用搜索框：毛玻璃半透明背景 + 主题色描边。
///
/// 统一各页面搜索框观感：5px 高斯模糊 + 半透明蒙层，深浅色主题下
/// 均呈现磨砂质感；聚焦时描边加粗为主题主色，失焦时为半透明主题色。
/// 支持自动清除按钮（showClearSuffix）与编辑完成回调拦截。
class FrostedSearchField extends StatefulWidget {
  const FrostedSearchField({
    super.key,
    this.controller,
    this.hintText,
    this.onChanged,
    this.onSubmitted,
    this.onEditingComplete,
    this.textInputAction = TextInputAction.search,
    this.autofocus = false,
    this.focusNode,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    this.suffix,
    this.showClearSuffix = false,
    this.onCleared,
  });

  final TextEditingController? controller;
  final String? hintText;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  /// 覆盖框架默认的“收到键盘动作即失焦收起键盘”行为（如搜索页
  /// 需要自行决定何时收起键盘）。
  final VoidCallback? onEditingComplete;
  final TextInputAction textInputAction;
  final bool autofocus;
  final FocusNode? focusNode;
  final EdgeInsetsGeometry padding;

  /// 追加在输入框内部右侧的控件（如关闭按钮）。
  final Widget? suffix;

  /// 输入非空时自动显示清除按钮，清空后回调 onChanged('')。
  final bool showClearSuffix;

  /// 自定义清除按钮行为（如搜索页需要同时重置搜索状态）；
  /// 未提供时默认清空文本并回调 onChanged('')。
  final VoidCallback? onCleared;

  @override
  State<FrostedSearchField> createState() => _FrostedSearchFieldState();
}

class _FrostedSearchFieldState extends State<FrostedSearchField> {
  late final FocusNode _ownFocusNode;
  bool _focused = false;
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _ownFocusNode = widget.focusNode ?? FocusNode();
    _ownFocusNode.addListener(_handleFocusChange);
    final controller = widget.controller;
    if (controller != null) {
      _hasText = controller.text.isNotEmpty;
      controller.addListener(_handleControllerChange);
    }
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ownFocusNode.requestFocus();
      });
    }
  }

  void _handleFocusChange() {
    final focused = _ownFocusNode.hasFocus;
    if (focused != _focused) setState(() => _focused = focused);
  }

  void _handleControllerChange() {
    final hasText = widget.controller?.text.isNotEmpty ?? false;
    if (hasText != _hasText) setState(() => _hasText = hasText);
  }

  void _clear() {
    if (widget.onCleared != null) {
      widget.onCleared!();
      return;
    }
    widget.controller?.clear();
    widget.onChanged?.call('');
  }

  @override
  void dispose() {
    _ownFocusNode.removeListener(_handleFocusChange);
    widget.controller?.removeListener(_handleControllerChange);
    if (widget.focusNode == null) _ownFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: widget.padding,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
          child: TextField(
            controller: widget.controller,
            focusNode: _ownFocusNode,
            onChanged: widget.onChanged,
            onSubmitted: widget.onSubmitted,
            onEditingComplete: widget.onEditingComplete,
            textInputAction: widget.textInputAction,
            style: TextStyle(color: scheme.onSurface),
            cursorColor: scheme.primary,
            decoration: InputDecoration(
              hintText: widget.hintText ?? '搜索歌曲、歌手、专辑',
              hintStyle: TextStyle(
                color: scheme.onSurfaceVariant.withValues(alpha: .7),
              ),
              prefixIcon: Icon(
                Icons.search_rounded,
                color: scheme.onSurfaceVariant,
              ),
              suffixIcon: _buildSuffix(scheme),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              filled: true,
              // 毛玻璃上的浅色蒙层：透出下方列表内容，同时保证文字可读。
              fillColor: scheme.surfaceContainerHighest.withValues(alpha: .35),
              border: _border(scheme, focused: _focused),
              enabledBorder: _border(scheme, focused: false),
              focusedBorder: _border(scheme, focused: true),
            ),
          ),
        ),
      ),
    );
  }

  Widget? _buildSuffix(ColorScheme scheme) {
    if (widget.suffix != null) return widget.suffix;
    if (widget.showClearSuffix && _hasText) {
      return IconButton(
        tooltip: '清除',
        visualDensity: VisualDensity.compact,
        onPressed: _clear,
        icon: Icon(
          Icons.clear_rounded,
          size: 20,
          color: scheme.onSurfaceVariant,
        ),
      );
    }
    return null;
  }

  OutlineInputBorder _border(ColorScheme scheme, {required bool focused}) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(24),
        borderSide: BorderSide(
          color: scheme.primary.withValues(alpha: focused ? .9 : .45),
          width: focused ? 1.6 : 1,
        ),
      );
}
