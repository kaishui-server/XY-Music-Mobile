import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 插件 ID 漂移后的存量数据迁移。
///
/// 订阅插件更新后 metadata.name 变化（如加上「(赞助版)[永久]」后缀）
/// 或旧版本安装时走了内容哈希回退（plugin-188b76fb），重新计算出的
/// 插件 ID 与旧文件名不一致。安装去重会把旧 ID 文件删除、偏好迁移到
/// 新 ID，但歌单/收藏/最近播放里引用旧 ID 的歌曲会全部断链：
/// path 前缀 `plugin://旧ID/` 与 pluginId 字段都查不到插件。
///
/// 本函数把 SharedPreferences 中所有旧 ID 引用改写为新 ID：
/// - 歌单（mobilePlaylistsV1）：songPaths、customOrder、快照键与
///   path/pluginId、songSources 键与 `plugin:`/`lx:` 来源键、
///   importSources.pluginId；
/// - 收藏：favoritePaths、favoriteSongMetadataV1、favoriteCustomOrderV1；
/// - 最近播放快照（recentSongMetadataV1）：仅 pluginId 字段——path 是
///   SQLite 播放历史的关联键，改写会让历史记录反查不到快照。
///
/// 返回发生改写的歌曲引用条数（0 表示无引用需要迁移）。
Future<int> migratePluginReferences(Map<String, String> idRenames) async {
  final renames = <String, String>{
    for (final entry in idRenames.entries)
      if (entry.key.isNotEmpty &&
          entry.value.isNotEmpty &&
          entry.key != entry.value)
        entry.key: entry.value,
  };
  if (renames.isEmpty) return 0;

  // 歌曲身份即 path：`plugin://插件ID/歌曲ID`，插件 ID 生成时做了
  // URL 编码（纯 ASCII ID 编码后不变，中文 ID 编码为 %XX 形式）。
  String? rewritePath(String path) {
    for (final entry in renames.entries) {
      final prefix = 'plugin://${Uri.encodeComponent(entry.key)}/';
      if (path.startsWith(prefix)) {
        return 'plugin://${Uri.encodeComponent(entry.value)}/'
            '${path.substring(prefix.length)}';
      }
    }
    return null;
  }

  String? rewriteId(String? id) =>
      id == null || id.isEmpty ? null : renames[id];

  // songSources 的来源身份键：`plugin:插件ID` / `lx:插件ID`（原始 ID）。
  String? rewriteSourceKey(String key) {
    for (final prefix in const ['plugin:', 'lx:']) {
      if (key.startsWith(prefix)) {
        final mapped = renames[key.substring(prefix.length)];
        if (mapped != null) return '$prefix$mapped';
        return null;
      }
    }
    return null;
  }

  var changed = 0;
  final prefs = await SharedPreferences.getInstance();

  // ---- 歌单 ----
  final playlistsRaw = prefs.getString('mobilePlaylistsV1');
  if (playlistsRaw != null && playlistsRaw.isNotEmpty) {
    try {
      final decoded = jsonDecode(playlistsRaw);
      if (decoded is List) {
        var playlistChanged = false;
        final playlists = <Map<String, dynamic>>[];
        for (final item in decoded) {
          if (item is! Map) continue;
          final playlist = Map<String, dynamic>.from(item);
          var touched = false;

          String? mapPath(String path) {
            final rewritten = rewritePath(path);
            if (rewritten != null) touched = true;
            return rewritten;
          }

          final songPaths = (playlist['songPaths'] as List?)
              ?.map((e) => e.toString())
              .toList(growable: false);
          if (songPaths != null) {
            final rewritten = [
              for (final path in songPaths) mapPath(path) ?? path,
            ];
            if (touched) {
              playlist['songPaths'] = rewritten;
              changed += _countChanged(songPaths, rewritten);
            }
          }

          if (touched) {
            final customOrder = (playlist['customOrder'] as List?)
                ?.map((e) => e.toString())
                .toList(growable: false);
            if (customOrder != null) {
              playlist['customOrder'] = [
                for (final path in customOrder) rewritePath(path) ?? path,
              ];
            }
          }

          final snapshots = playlist['songSnapshots'];
          if (snapshots is Map) {
            final newSnapshots = <String, dynamic>{};
            for (final entry in snapshots.entries) {
              final oldKey = entry.key.toString();
              var newKey = rewritePath(oldKey) ?? oldKey;
              var value = entry.value;
              if (value is Map) {
                final snapshot = Map<String, dynamic>.from(value);
                final newPath = rewritePath(snapshot['path']?.toString() ?? '');
                if (newPath != null) {
                  snapshot['path'] = newPath;
                }
                final newPluginId = rewriteId(snapshot['pluginId']?.toString());
                if (newPluginId != null) {
                  snapshot['pluginId'] = newPluginId;
                }
                if (newPath != null || newPluginId != null) {
                  changed++;
                  touched = true;
                }
                value = snapshot;
              }
              newSnapshots[newKey] = value;
            }
            if (touched) playlist['songSnapshots'] = newSnapshots;
          }

          final songSources = playlist['songSources'];
          if (songSources is Map && touched) {
            final newSources = <String, dynamic>{};
            for (final entry in songSources.entries) {
              final newKey =
                  rewritePath(entry.key.toString()) ?? entry.key.toString();
              final keys = (entry.value as List?)
                  ?.map((e) => e.toString())
                  .toList(growable: false);
              newSources[newKey] = keys == null
                  ? entry.value
                  : [for (final key in keys) rewriteSourceKey(key) ?? key];
            }
            playlist['songSources'] = newSources;
          }

          final importSources = playlist['importSources'];
          if (importSources is List && touched) {
            playlist['importSources'] = [
              for (final source in importSources)
                if (source is Map)
                  () {
                    final mapped = Map<String, dynamic>.from(source);
                    final newPluginId = rewriteId(
                      mapped['pluginId']?.toString(),
                    );
                    if (newPluginId != null) {
                      mapped['pluginId'] = newPluginId;
                    }
                    return mapped;
                  }()
                else
                  source,
            ];
          }

          if (touched) playlistChanged = true;
          playlists.add(playlist);
        }
        if (playlistChanged) {
          await prefs.setString('mobilePlaylistsV1', jsonEncode(playlists));
        }
      }
    } catch (_) {
      // 单个键解析失败不应阻断其余数据迁移；下次合并会再次尝试。
    }
  }

  // ---- 收藏路径集合 ----
  final favoritePaths = prefs.getStringList('favoritePaths');
  if (favoritePaths != null && favoritePaths.isNotEmpty) {
    final rewritten = [
      for (final path in favoritePaths) rewritePath(path) ?? path,
    ];
    if (_countChanged(favoritePaths, rewritten) > 0) {
      changed += _countChanged(favoritePaths, rewritten);
      await prefs.setStringList('favoritePaths', rewritten);
      final order = prefs.getStringList('favoriteCustomOrderV1');
      if (order != null) {
        await prefs.setStringList('favoriteCustomOrderV1', [
          for (final path in order) rewritePath(path) ?? path,
        ]);
      }
    }
  }

  // ---- 收藏歌曲快照 ----
  await _migrateSnapshotMap(
    prefs,
    'favoriteSongMetadataV1',
    rewritePath: rewritePath,
    rewriteId: rewriteId,
    onMigrated: () => changed++,
  );

  // ---- 最近播放快照：path 与 SQLite 历史关联，只迁移 pluginId ----
  await _migrateSnapshotMap(
    prefs,
    'recentSongMetadataV1',
    rewritePath: (_) => null,
    rewriteId: rewriteId,
    onMigrated: () => changed++,
  );

  return changed;
}

int _countChanged(List<String> before, List<String> after) {
  var count = 0;
  for (var i = 0; i < before.length && i < after.length; i++) {
    if (before[i] != after[i]) count++;
  }
  return count;
}

/// 改写「路径到快照 JSON 的映射」形态的存储（收藏/最近播放网络歌曲
/// 快照）。
Future<void> _migrateSnapshotMap(
  SharedPreferences prefs,
  String key, {
  required String? Function(String) rewritePath,
  required String? Function(String?) rewriteId,
  required void Function() onMigrated,
}) async {
  final raw = prefs.getString(key);
  if (raw == null || raw.isEmpty) return;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return;
    var changed = false;
    final result = <String, dynamic>{};
    for (final entry in decoded.entries) {
      final oldKey = entry.key.toString();
      final newKey = rewritePath(oldKey) ?? oldKey;
      var value = entry.value;
      if (value is Map) {
        final snapshot = Map<String, dynamic>.from(value);
        final newPath = rewritePath(snapshot['path']?.toString() ?? '');
        if (newPath != null) snapshot['path'] = newPath;
        final newPluginId = rewriteId(snapshot['pluginId']?.toString());
        if (newPluginId != null) snapshot['pluginId'] = newPluginId;
        if (newPath != null || newPluginId != null) {
          changed = true;
          onMigrated();
        }
        value = snapshot;
      }
      result[newKey] = value;
    }
    if (changed) {
      await prefs.setString(
        key,
        jsonEncode(result, toEncodable: (value) => value.toString()),
      );
    }
  } catch (_) {
    // 解析失败时保持原样，不阻断其余迁移。
  }
}
