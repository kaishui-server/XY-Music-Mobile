import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 在线歌曲自定义封面覆盖表（song.path → 封面地址）。
///
/// 在线歌曲没有本地文件可写 tag，封面编辑结果统一落盘为应用内图片
/// 文件，以 `file://` 绝对路径记录在此表；也可直接记录网络 URL。
/// 封面消费点通过 [resolveOnlineCoverUrl] 优先取覆盖值，未命中回退
/// 原始 coverUrl。
///
/// 进程内静态缓存 + [onlineCoverRevision] 变更通知：编辑页保存后
/// revision 自增，列表封面（SongCover 内 ValueListenableBuilder）等
/// 消费点据此刷新，无需引入 provider 依赖。

const String _kOnlineCoverOverrides = 'onlineCoverOverridesV1';

final Map<String, String> _overrides = <String, String>{};
bool _loaded = false;

/// 覆盖表变更序号：任何写入（含启动异步加载完成）后自增。
final ValueNotifier<int> onlineCoverRevision = ValueNotifier<int>(0);

Future<void> initOnlineCoverOverrides() async {
  if (_loaded) return;
  _loaded = true;
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kOnlineCoverOverrides);
    if (raw != null) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        _overrides.addAll({
          for (final entry in decoded.entries)
            if (entry.value is String) entry.key.toString(): entry.value as String,
        });
      }
    }
  } catch (_) {
    // 损坏的存档按空表处理，不影响正常播放。
  }
  onlineCoverRevision.value++;
}

/// 设置/清除在线歌曲自定义封面：[coverUrl] 空串表示清除（回退原封面）。
Future<void> setOnlineSongCover(String songPath, String coverUrl) async {
  final trimmed = coverUrl.trim();
  if (trimmed.isEmpty) {
    _overrides.remove(songPath);
  } else {
    _overrides[songPath] = trimmed;
  }
  onlineCoverRevision.value++;
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kOnlineCoverOverrides, jsonEncode(_overrides));
  } catch (_) {
    // 持久化失败不影响本次会话内的显示。
  }
}

/// 封面消费点统一入口：覆盖值优先（`file://` 或网络 URL），否则原值。
String? resolveOnlineCoverUrl(String? coverUrl, String? songPath) {
  if (songPath != null && songPath.isNotEmpty) {
    final over = _overrides[songPath];
    if (over != null && over.isNotEmpty) return over;
  }
  return coverUrl;
}
