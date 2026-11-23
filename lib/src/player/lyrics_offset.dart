import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../lyrics/lyrics_models.dart';

/// 每首歌歌词偏移（单位 0.1 秒）的持久化键：`{songPath: tenths}`。
///
/// 播放详情页（`player_page.dart`）读写同一份 prefs，底栏迷你歌词也读它，
/// 保证「居中歌词」和「迷你歌词」按同一个偏移换行。
const lyricsOffsetsPreferenceKey = 'playerLyricsOffsetsTenthsV1';

/// 某首歌的歌词偏移（0.1 秒）；未设置时为 0。
///
/// 迷你歌词用它把播放位置换算成与居中歌词一致的换行时刻。播放页修改偏移后
/// 会 `ref.invalidate` 本 provider，两处立即同步。
final lyricsOffsetTenthsProvider = FutureProvider.family<int, String>((
  ref,
  songPath,
) async {
  final prefs = await SharedPreferences.getInstance();
  try {
    final raw = prefs.getString(lyricsOffsetsPreferenceKey);
    if (raw == null || raw.isEmpty) return 0;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return 0;
    return clampLyricOffsetTenths((decoded[songPath] as num?)?.toInt() ?? 0);
  } catch (_) {
    return 0;
  }
});
