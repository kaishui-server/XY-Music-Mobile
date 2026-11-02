import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'plugin_metadata.dart';

/// 插件管理页后台加载器（治「插件多时页面加载 10 秒转圈」）。
///
/// 参考桌面 MusicFree 的做法：页面不再在主线程逐个读取 + 正则解析
/// 全部插件脚本（单个脚本可达数百 KB，几十个插件累计是数秒的
/// 文件 IO + 纯 CPU），而是：
/// 1. 整个「列目录 → 读脚本 → PluginMetadata.parse → 分类判定 →
///    排序」都放到后台 isolate（`Isolate.run`），主线程零阻塞；
/// 2. 解析出的元数据按「文件名 + size + mtime」持久化缓存到插件
///    目录下 `meta_cache.json`，文件未变化时直接复用（进页面毫秒级）；
///    仅安装/更新过的文件才重新解析一次。
///
/// 缓存只存脚本内容派生的元数据；分类覆盖（kinds）、显示名、启用
/// 状态等 prefs 数据由调用方在主 isolate 读取后传入，改类/改名
/// 仍然即时生效，不受缓存影响。
const _metaCacheFileName = 'meta_cache.json';
const _metaCacheVersion = 1;

/// 后台加载全部插件行（plain map，可跨 isolate 传输）。
/// 返回的行字段见 [_rowFromMeta]；kind 为分类标识字符串
/// （baka/musicfree/lx/animemusic/other，与
/// plugin_runtime.dart 的 pluginKind* 常量一致）。
Future<List<Map<String, Object?>>> loadPluginRowsInBackground({
  required String pluginsDir,
  required Set<String> enabled,
  required Map<String, String> sourceUrls,
  required Map<String, String> displayNames,
  required Map<String, String> sourceLabels,
  required Map<String, String> kinds,
  required List<String> orderedIds,
}) {
  return Isolate.run(() async {
    final rows = <Map<String, Object?>>[];
    final directory = Directory(pluginsDir);
    if (!directory.existsSync()) return rows;
    final files =
        directory
            .listSync()
            .whereType<File>()
            .where((file) => p.extension(file.path).toLowerCase() == '.js')
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));

    // 读取上次的元数据缓存（损坏/缺失时视为空）。
    var cacheChanged = false;
    Map<String, Object?> oldCache = const {};
    final cacheFile = File(p.join(pluginsDir, _metaCacheFileName));
    try {
      if (cacheFile.existsSync()) {
        final decoded = jsonDecode(cacheFile.readAsStringSync());
        if (decoded is Map) oldCache = Map<String, Object?>.from(decoded);
      }
    } catch (_) {
      oldCache = const {};
    }
    if ((oldCache['v'] as num?)?.toInt() != _metaCacheVersion) {
      oldCache = const {};
    }
    final oldFiles = oldCache['files'];
    final cachedFiles = oldFiles is Map
        ? Map<String, Object?>.from(oldFiles)
        : <String, Object?>{};
    final newCacheFiles = <String, Object?>{};

    for (final file in files) {
      final fileName = p.basename(file.path);
      FileStat stat;
      try {
        stat = file.statSync();
      } catch (_) {
        continue; // 文件恰好被删除等，跳过。
      }
      final size = stat.size;
      final mtime = stat.modified.millisecondsSinceEpoch;

      Map<String, Object?> meta;
      final cached = cachedFiles[fileName];
      if (cached is Map &&
          (cached['size'] as num?)?.toInt() == size &&
          (cached['mtime'] as num?)?.toInt() == mtime) {
        // 缓存命中：文件名 + size + mtime 均未变，直接复用解析结果。
        meta = Map<String, Object?>.from(
          (cached['meta'] as Map?) ?? const {},
        );
      } else {
        // 未命中（新装/更新过的插件）：完整解析一次并更新缓存。
        try {
          final script = await file.readAsString();
          meta = _metaToJson(PluginMetadata.parse(script));
        } catch (_) {
          meta = const {};
        }
        newCacheFiles[fileName] = {'size': size, 'mtime': mtime, 'meta': meta};
        cacheChanged = true;
      }
      newCacheFiles[fileName] = newCacheFiles[fileName] ??
          cachedFiles[fileName] ??
          {'size': size, 'mtime': mtime, 'meta': meta};

      final id = p.basenameWithoutExtension(file.path);
      rows.add(
        _rowFromMeta(
          id: id,
          path: file.path,
          meta: meta,
          enabled: enabled.contains(id),
          displayName: displayNames[id],
          sourceUrl: sourceUrls[id],
          sourceLabel: sourceLabels[id],
          kinds: kinds,
        ),
      );
    }

    // 仅在解析过新文件时写回缓存（纯浏览不写盘）。写失败不影响加载。
    if (cacheChanged) {
      try {
        cacheFile.writeAsStringSync(
          jsonEncode({'v': _metaCacheVersion, 'files': newCacheFiles}),
        );
      } catch (_) {}
    }

    // 拖拽保存的顺序优先；未记录过的插件（新安装）按文件名顺序追加在后。
    if (orderedIds.isNotEmpty) {
      final byId = {for (final row in rows) row['id'] as String: row};
      final ordered = <Map<String, Object?>>[];
      for (final id in orderedIds) {
        final row = byId.remove(id);
        if (row != null) ordered.add(row);
      }
      ordered.addAll(byId.values);
      return ordered;
    }
    return rows;
  });
}

Map<String, Object?> _rowFromMeta({
  required String id,
  required String path,
  required Map<String, Object?> meta,
  required bool enabled,
  String? displayName,
  String? sourceUrl,
  String? sourceLabel,
  required Map<String, String> kinds,
}) {
  final isLx = meta['isLx'] == true;
  final isBaka = meta['isBaka'] == true;
  final isAnimemusic = meta['isAnimemusic'] == true;
  // 分类优先级：LX 契约 > BakaMusic 契约 > animemusic 后端 > 标准
  // MusicFree。与迁移前的 _load 判定一致（v2 洛雪版虽直连 animemusic
  // 后端但属 LX 契约；baka 版兜底地址同样指向 animemusic 域名，需先判
  // Baka）。内容识别不中时用订阅类型提示与来源 URL 兜底；手动归入
  // 「其他」是明确用户意图，优先于自动识别。详见 plugin_metadata.dart
  // 的 _detectBaka / isBakaSourceUrl 注释。
  var kind = isLx
      ? 'lx'
      : isBaka
      ? 'baka'
      : isAnimemusic
      ? 'animemusic'
      : 'musicfree';
  final kindHint = kinds[id];
  if (kindHint == 'other') {
    kind = 'other';
  } else if (kind == 'musicfree' || kind == 'baka') {
    if (kindHint == 'baka') {
      kind = 'baka';
    } else if (kindHint == 'musicfree') {
      // 内容已判定为 Baka 契约时不被 musicfree 提示压回。
      if (kind != 'baka') kind = 'musicfree';
    } else if (PluginMetadata.isBakaSourceUrl(sourceUrl ?? '')) {
      kind = 'baka';
    }
  }

  final userVariables = <Map<String, String>>[
    for (final raw in (meta['userVariables'] as List? ?? const []))
      if (raw is Map)
        {
          'key': raw['key']?.toString() ?? '',
          'name': raw['name']?.toString() ?? '',
          'hint': raw['hint']?.toString() ?? '',
        },
  ];

  return {
    'id': id,
    'path': path,
    'enabled': enabled,
    'kind': kind,
    'name': (displayName?.trim().isNotEmpty == true
            ? displayName
            : meta['name']?.toString()) ??
        id,
    'version': meta['version']?.toString() ?? '未知版本',
    'author': meta['author']?.toString(),
    'remark': meta['remark']?.toString(),
    'sourceUrl': sourceUrl,
    'sourceLabel': sourceLabel,
    'userVariables': userVariables,
    'isStarSea': meta['isStarSea'] == true,
  };
}

/// PluginMetadata → 可缓存/可跨 isolate 的 JSON 结构。
Map<String, Object?> _metaToJson(PluginMetadata m) => {
  'name': m.name,
  'version': m.version,
  'author': m.author,
  'remark': m.remark,
  'userVariables': [
    for (final v in m.userVariables)
      {'key': v.key, 'name': v.name, 'hint': v.hint},
  ],
  'isStarSea': m.isStarSea,
  'isLx': m.isLx,
  'isBaka': m.isBaka,
  'isAnimemusic': m.isAnimemusic,
};
