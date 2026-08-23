import 'dart:convert';

import 'package:flutter/material.dart';

/// 显示服务端用户头像。
///
/// 服务端为了兼容桌面端会直接返回 data:image/...;base64,...，
/// 这类地址不能交给 Image.network 处理，需要先解码成内存图片。
class UserAvatarImage extends StatelessWidget {
  const UserAvatarImage({
    super.key,
    required this.source,
    this.fit = BoxFit.cover,
    this.errorBuilder,
  });

  final String source;
  final BoxFit fit;
  final ImageErrorWidgetBuilder? errorBuilder;

  @override
  Widget build(BuildContext context) {
    final value = source.trim();
    if (value.startsWith('data:image/')) {
      final comma = value.indexOf(',');
      if (comma > 0 && comma < value.length - 1) {
        try {
          final bytes = base64Decode(value.substring(comma + 1));
          return Image.memory(
            bytes,
            key: ValueKey(value),
            fit: fit,
            errorBuilder: errorBuilder,
          );
        } catch (_) {
          return errorBuilder?.call(
                context,
                const FormatException('头像数据无效'),
                StackTrace.current,
              ) ??
              const SizedBox.shrink();
        }
      }
    }
    return Image.network(
      value,
      key: ValueKey(value),
      fit: fit,
      errorBuilder: errorBuilder,
    );
  }
}
