import 'dart:convert';

import 'playlists_provider.dart';

/// XY Music 歌单文件格式标识（新版导出为 .json，旧版为 .xyplaylist，
/// 导入端按内容中的 format 字段识别，两种扩展名均兼容）。
const kXyPlaylistFormat = 'xy-playlist';

/// 当前导出的格式版本（导入端按此做兼容判断）。
const kXyPlaylistFileVersion = 1;

/// 解析后的 XY Music 歌单文件数据。
class XyPlaylistFileData {
  const XyPlaylistFileData({
    required this.name,
    required this.songPaths,
    required this.songSnapshots,
    this.coverUrl,
    this.customOrder,
  });

  final String name;
  final String? coverUrl;

  /// 歌曲顺序（path 列表，快照与本地路径混排）。
  final List<String> songPaths;

  /// 在线歌曲快照（网络歌曲跨设备导入的载体）。
  final Map<String, PlaylistSongSnapshot> songSnapshots;

  /// 用户自定义顺序（可选，仅当歌曲完整时恢复）。
  final List<String>? customOrder;
}

/// 组装 XY Music 歌单文件内容（JSON Map，调用方负责序列化与保存）。
Map<String, dynamic> buildXyPlaylistFile(MobilePlaylist playlist) => {
  'app': 'XY Music',
  'format': kXyPlaylistFormat,
  'version': kXyPlaylistFileVersion,
  'exportedAt': DateTime.now().toIso8601String(),
  'playlist': {
    'name': playlist.name,
    'coverUrl': playlist.coverUrl,
    'songPaths': playlist.songPaths,
    'songSnapshots': {
      for (final entry in playlist.songSnapshots.entries)
        entry.key: entry.value.toJson(),
    },
    if (playlist.customOrder != null) 'customOrder': playlist.customOrder,
  },
};

/// 解析 XY Music 歌单文件内容；结构不符时抛 FormatException。
XyPlaylistFileData parseXyPlaylistFile(String content) {
  Object? json;
  try {
    json = jsonDecode(content);
  } catch (_) {
    throw const FormatException('不是有效的 XY Music 歌单文件');
  }
  if (json is! Map || json['format'] != kXyPlaylistFormat) {
    throw const FormatException('不是有效的 XY Music 歌单文件');
  }
  final playlist = json['playlist'];
  if (playlist is! Map) {
    throw const FormatException('歌单文件缺少歌单数据');
  }
  final songPaths = (playlist['songPaths'] as List? ?? const [])
      .whereType<String>()
      .toList();
  final snapshots = playlist['songSnapshots'] is Map
      ? (playlist['songSnapshots'] as Map).map(
          (key, value) => MapEntry(
            key.toString(),
            PlaylistSongSnapshot.fromJson(
              Map<String, dynamic>.from(value as Map),
            ),
          ),
        )
      : const <String, PlaylistSongSnapshot>{};
  return XyPlaylistFileData(
    name: (playlist['name'] as String?)?.trim().isNotEmpty == true
        ? playlist['name'] as String
        : '导入的歌单',
    coverUrl: playlist['coverUrl'] as String?,
    songPaths: songPaths,
    songSnapshots: snapshots,
    customOrder: (playlist['customOrder'] as List?)?.whereType<String>().toList(),
  );
}
