import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../src/core/db_path.dart';
import '../../src/core/settings.dart';
import '../../src/favorites/favorites_provider.dart';
import '../../src/player/player_provider.dart';
import '../../src/playlists/playlists_provider.dart';
import '../../src/plugins/plugin_metadata.dart';
import '../../src/plugins/plugin_reference_migration.dart';
import '../../src/plugins/plugin_runtime.dart';
import '../../src/recent/recent_provider.dart';
import '../../src/rust/api.dart';
import '../../src/ui/xy_surface.dart';
import '../../src/ui/xy_theme.dart';
import '../../src/widgets/top_notice.dart';
import '../../src/navigation/sidebar_controller.dart';

/// 插件分类：按契约与后端分为四页展示。
enum _PluginKind {
  /// BakaMusic 契约插件（animeSrc 来源标记）。
  baka,

  /// 标准 MusicFree 插件（module.exports 契约、无特殊后端标记）。
  musicfree,

  /// LX（洛雪）音源插件（globalThis.lx 契约）。
  lx,

  /// animemusic 后端插件（直连 animemusic.bzxhkj.com，惜梦 v3/v4 等）。
  animemusic,

  /// 其他：不属于上述契约族、或用户手动归位的插件。仅影响分栏展示，
  /// 播放时仍按脚本内容识别契约。
  other,
}

class _PluginInfo {
  const _PluginInfo({
    required this.id,
    required this.name,
    required this.version,
    required this.path,
    required this.enabled,
    required this.kind,
    this.author,
    this.remark,
    this.sourceUrl,
    this.sourceLabel,
    this.userVariables = const [],
    this.isStarSea = false,
  });

  final String id;
  final String name;
  final String version;
  final String path;
  final bool enabled;
  final String? author;
  final String? remark;
  final String? sourceUrl;

  /// 多租户订阅源标识（IKUN / 聆澜…）：同一订阅里按 `?source=` 发放的
  /// 专属脚本，安装时记下来源，列表中在名称旁以小标签展示。
  final String? sourceLabel;
  final List<PluginUserVariable> userVariables;

  /// 星海格式插件（带 _src 来源标记的聚合变体，如惜梦 v4）。
  final bool isStarSea;

  /// 插件分类（BakaMusic/MusicFree/LX/animemusic/其他）。
  final _PluginKind kind;

  bool get isOnline => sourceUrl?.trim().isNotEmpty == true;
}

class _InstallSummary {
  const _InstallSummary({
    required this.installed,
    required this.skipped,
    required this.failed,
    required this.names,
    required this.errors,
  });

  final int installed;
  final int skipped;
  final int failed;
  final List<String> names;
  final List<String> errors;

  String get message {
    if (installed == 1 && skipped == 0 && failed == 0) {
      return '已安装并启用 ${names.first}';
    }
    final parts = <String>['成功 $installed 个'];
    if (skipped > 0) parts.add('跳过 $skipped 个');
    if (failed > 0) parts.add('失败 $failed 个');
    return parts.join('，');
  }
}

class _MutableInstallSummary {
  int installed = 0;
  int skipped = 0;
  int failed = 0;
  final names = <String>[];
  final errors = <String>[];

  _InstallSummary freeze() => _InstallSummary(
    installed: installed,
    skipped: skipped,
    failed: failed,
    names: List.unmodifiable(names),
    errors: List.unmodifiable(errors),
  );
}

/// 批量安装期间的插件目录索引：把「插件 ID → 磁盘文件」的映射只扫描
/// 解析一次，并在写入新文件后增量维护。
///
/// 原实现每安装一个插件都全目录 `readAsStringSync` + `PluginMetadata
/// .parse`（几十个正则跑在整段脚本上）来查重；批量导入 N 个插件会退化
/// 成 O(N²) 次读取与解析。脚本可达数百 KB 时，主线程被长时间占满，
/// 中低端机上直接 ANR / 闪退（用户实测导入到第 15 个左右崩溃）。
class _PluginIdIndex {
  _PluginIdIndex(this.directory);

  final Directory directory;
  Map<String, List<File>>? _index;

  /// 首次调用时全量扫描一次；index 为 null 表示尚未扫描。
  Future<Map<String, List<File>>> _ensure() async {
    final cached = _index;
    if (cached != null) return cached;
    final index = <String, List<File>>{};
    if (directory.existsSync()) {
      final files =
          directory
              .listSync()
              .whereType<File>()
              .where((file) => p.extension(file.path).toLowerCase() == '.js')
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      for (final file in files) {
        String id;
        try {
          // 与旧逻辑保持一致：按「脚本内容 + 来源路径」算出 ID 后查重。
          id = PluginMetadata.resolvePluginId(
            await file.readAsString(),
            file.path,
          );
        } catch (_) {
          id = p.basenameWithoutExtension(file.path);
        }
        index.putIfAbsent(id, () => <File>[]).add(file);
      }
    }
    _index = index;
    return index;
  }

  /// 返回磁盘上 ID 相同的全部副本（含主文件）。尚未扫描时不触发扫描，
  /// 由调用方决定是否查询。
  Future<List<File>> duplicatesOf(String id) async {
    final index = await _ensure();
    return List<File>.unmodifiable(index[id] ?? const <File>[]);
  }

  /// 新写入插件后登记，避免同批次后续插件重复扫描目录。
  void register(String id, File file) {
    final index = _index;
    if (index == null) return;
    index.putIfAbsent(id, () => <File>[]).add(file);
  }

  /// 删除/合并后移除登记，保持索引与磁盘一致。
  void unregister(Iterable<File> files) {
    final index = _index;
    if (index == null) return;
    final paths = files.map((file) => file.path).toSet();
    for (final entry in index.entries) {
      entry.value.removeWhere((file) => paths.contains(file.path));
    }
    index.removeWhere((_, value) => value.isEmpty);
  }
}

class _PluginsNotifier extends AsyncNotifier<List<_PluginInfo>> {
  static const _enabledKey = 'mobileEnabledPlugins';
  static const _sourceUrlsKey = 'mobilePluginSourceUrlsV1';
  static const _maxPluginBytes = 5 * 1024 * 1024;
  static const _maxIndexItems = 100;

  @override
  Future<List<_PluginInfo>> build() => _load();

  Future<List<_PluginInfo>> _load() async {
    final dataDir = await ref.read(appDataDirProvider.future);
    final directory = Directory(p.join(dataDir, 'plugins'));
    if (!directory.existsSync()) return const [];
    final prefs = await SharedPreferences.getInstance();
    final enabled = (prefs.getStringList(_enabledKey) ?? const []).toSet();
    final sourceUrls = _readSourceUrls(prefs);
    final displayNames = readPluginDisplayNames(prefs);
    final sourceLabels = readPluginSourceLabels(prefs);
    final kinds = readPluginKinds(prefs);
    final files =
        directory
            .listSync()
            .whereType<File>()
            .where((file) => p.extension(file.path).toLowerCase() == '.js')
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    // 逐文件异步读取：脚本可达数百 KB，批量装了几十个后若同步读完整个
    // 目录会长时间阻塞主线程；await 读取会在文件之间让出事件循环。
    final items = <_PluginInfo>[];
    for (final file in files) {
      final script = await file.readAsString();
      final metadata = PluginMetadata.parse(script);
      final id = p.basenameWithoutExtension(file.path);
      // 分类优先级：LX 契约 > BakaMusic 契约 > animemusic 后端 >
      // 标准 MusicFree。v2 洛雪版虽直连 animemusic 后端但属 LX 契约；
      // baka 版兜底地址同样指向 animemusic 域名，需先判 Baka。
      var kind = metadata.isLx
          ? _PluginKind.lx
          : metadata.isBaka
          ? _PluginKind.baka
          : metadata.isAnimemusic
          ? _PluginKind.animemusic
          : _PluginKind.musicfree;
      // BakaMusic 与 MusicFree 脚本大量同构，分类顺序：内容证据
      // （metadata.isBaka 的 animeSrc / MV 组合标记）> 已记录的订阅类型提示
      // > 来源 URL。内容判为 Baka 时不被 musicfree 提示压回（见下）；
      // 内容判不中时用提示——它来自订阅结构判定或插件信息弹窗的手动改类，
      // 是明确意图；URL 仅作提示缺失时的兜底。
      //
      // URL 不能优先：同 ID 插件被另一族的插件覆盖时来源 URL 会从旧插件
      // 继承（本地导入不写 http 来源，旧的 Baka 订阅 URL 会留存），此时
      // Baka URL 会把新装的 MusicFree 插件错误顶到 BakaMusic 分栏，手动
      // 改类也会被它反复覆盖、看似无效。
      // 手动归入「其他」是明确的用户意图，优先于自动识别（含 LX/animemusic），
      // 只影响分栏展示，不改播放契约。
      if (kinds[id] == pluginKindOther) {
        kind = _PluginKind.other;
      } else if (kind == _PluginKind.musicfree || kind == _PluginKind.baka) {
        final kindHint = kinds[id];
        if (kindHint == pluginKindBaka) {
          kind = _PluginKind.baka;
        } else if (kindHint == pluginKindMusicFree) {
          // 内容已判定为 Baka 契约（animeSrc / getMvSource+supportedVideo
          // Qualities）时不采纳 musicfree 提示：该提示多半只是「导入时所在
          // 分栏」，而插件本身是 Baka 契约（QQ音乐[L1]/[L2] 单文件导入即如此）。
          if (kind != _PluginKind.baka) kind = _PluginKind.musicfree;
        } else if (PluginMetadata.isBakaSourceUrl(sourceUrls[id] ?? '')) {
          kind = _PluginKind.baka;
        }
      }
      items.add(
        _PluginInfo(
          id: id,
          name: displayNames[id] ?? metadata.name ?? id,
          version: metadata.version ?? '未知版本',
          author: metadata.author,
          remark: metadata.remark,
          path: file.path,
          enabled: enabled.contains(id),
          sourceUrl: sourceUrls[id],
          sourceLabel: sourceLabels[id],
          userVariables: metadata.userVariables,
          isStarSea: metadata.isStarSea,
          kind: kind,
        ),
      );
    }
    // 拖拽保存的顺序优先；未记录过的插件（新安装）按文件名顺序追加在后。
    final orderedIds = prefs.getStringList(pluginOrderKey) ?? const [];
    if (orderedIds.isNotEmpty) {
      final byId = {for (final item in items) item.id: item};
      final ordered = <_PluginInfo>[
        for (final id in orderedIds)
          if (byId.containsKey(id)) byId.remove(id)!,
      ];
      ordered.addAll(items.where((item) => byId.containsKey(item.id)));
      return ordered;
    }
    return items;
  }

  static Map<String, String> _readSourceUrls(SharedPreferences prefs) {
    try {
      final raw = prefs.getString(_sourceUrlsKey);
      if (raw == null) return {};
      return (jsonDecode(raw) as Map<String, dynamic>).map(
        (key, value) => MapEntry(key, value.toString()),
      );
    } catch (_) {
      return {};
    }
  }

  /// 创建一次批量安装共享的插件目录索引：同批次所有插件复用同一份
  /// 扫描结果，避免逐个插件重复全目录读取 + 正则解析（O(N²)）。
  Future<_PluginIdIndex> _newInstallIndex() async {
    final dataDir = await ref.read(appDataDirProvider.future);
    return _PluginIdIndex(Directory(p.join(dataDir, 'plugins')));
  }

  /// 批量安装的每个插件之间让出一次事件循环，避免长时间独占主线程
  /// 导致界面无响应（导入几十个插件时尤为明显）。
  Future<void> _yieldToUi() => Future<void>.delayed(Duration.zero);

  static void _validateScript(String script) {
    final trimmed = script.trim();
    if (trimmed.isEmpty) throw Exception('插件内容为空');
    if (utf8.encode(script).length > _maxPluginBytes) {
      throw Exception('插件超过 5 MB 安全限制');
    }
    final lower = trimmed.toLowerCase();
    if (lower.startsWith('<!doctype html') || lower.startsWith('<html')) {
      throw Exception('链接返回了网页，不是插件脚本');
    }
    final looksLikePlugin =
        lower.contains('@name') ||
        lower.contains('module.exports') ||
        lower.contains('export default') ||
        lower.contains('platform') ||
        lower.contains('musicfree') ||
        lower.contains('lx.') ||
        lower.contains('globalthis.lx') ||
        lower.contains('event_names.request') ||
        lower.contains('server_script_config');
    if (!looksLikePlugin) throw Exception('无法识别受支持的插件格式');
  }

  Future<String> _downloadText(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw Exception('请输入有效的 HTTP 或 HTTPS 地址');
    }
    final responseJson = await pluginHttpRequest(
      method: 'GET',
      url: uri.toString(),
      headersJson: const JsonEncoder().convert({'Accept': '*/*'}),
      timeout: BigInt.from(20),
      follow: 10,
    );
    final response = jsonDecode(responseJson) as Map<String, dynamic>;
    final status = (response['status'] as num?)?.toInt() ?? 0;
    if (status < 200 || status >= 300) throw Exception('下载失败：HTTP $status');
    final body = response['body'] as String? ?? '';
    if (body.isEmpty) throw Exception('服务器返回了空内容');
    return body;
  }

  /// 订阅源索引单条插件下载：URL 与订阅源同主机但未带显式端口
  /// （即默认 80）且下载失败时，改用订阅源端口重试一次。animemusic
  /// 这类订阅源的 JSON 里插件 URL 指向 80 端口，服务实际运行在订阅
  /// 源端口（如 19844）。返回脚本内容与最终生效的 URL（用于记录
  /// 插件来源，保证后续更新可用）。
  Future<(String, String)> _downloadIndexPlugin(
    String pluginUrl,
    Uri base,
  ) async {
    try {
      return (await _downloadText(pluginUrl), pluginUrl);
    } catch (firstError) {
      final uri = Uri.tryParse(pluginUrl);
      final sameHost =
          uri != null && uri.host.isNotEmpty && uri.host == base.host;
      final defaultPort = uri == null || !uri.hasPort || uri.port == 80;
      if (!sameHost || !defaultPort || !base.hasPort || base.port == 80) {
        rethrow;
      }
      final rewritten = uri.replace(port: base.port).toString();
      try {
        return (await _downloadText(rewritten), rewritten);
      } catch (_) {
        rethrow;
      }
    }
  }

  Future<bool> _persistScript(
    String script,
    String origin,
    _MutableInstallSummary summary, {
    String? displayName,
    String? kindHint,
    String? subscriptionSource,
    _PluginIdIndex? index,
  }) async {
    _validateScript(script);
    // 一次解析复用：ID 推导、显示名与版本读取共用同一份元数据，避免对
    // 同一段（可能数百 KB 的）脚本反复跑整套正则。
    final metadata = PluginMetadata.parse(script);
    final id = PluginMetadata.resolvePluginIdFromMetadata(metadata, origin);
    final indexName = displayName?.trim() ?? '';
    final source = subscriptionSource?.trim() ?? '';
    final sourceLabel = source.isEmpty ? '' : _subscriptionSourceLabel(source);
    // 多租户订阅源（BakaMusic 的 music.cwo.cc.cd 按 `?source=` 对同一插件
    // 发放不同授权的脚本）只记录来源标签用于界面区分，**不**改动插件 ID：
    // ID 一旦带后缀，歌曲/歌单里记录的旧 ID（如 `qq音乐`）就对不上新插件
    // （`qq音乐-ikun`），播放时报「歌曲所属插件已停用或删除」。同名插件按
    // 后装覆盖前装，界面上以来源标签标明当前装的是哪个渠道的版本。
    final name = indexName.isNotEmpty
        ? indexName
        : (metadata.name?.trim().isNotEmpty == true
              ? metadata.name!.trim()
              : id);

    final dataDir = await ref.read(appDataDirProvider.future);
    // 本地导入不依赖 Rust bridge。插件管理页可能在应用启动初始化 bridge
    // 完成前就被打开，直接调用 RustLib.instance 会触发
    // LateInitializationError；插件目录本身由 Dart 写入即可。
    final pluginsDir = Directory(p.join(dataDir, 'plugins'));
    await pluginsDir.create(recursive: true);

    final prefs = await SharedPreferences.getInstance();
    // 来源标签（IKUN / 聆澜…）随安装写入，供列表在音源名旁展示来源徽标。
    if (sourceLabel.isNotEmpty) {
      await _saveSourceLabel(prefs, id, sourceLabel);
    }

    // 磁盘级去重：批量安装中途 state 不会刷新，列表项名称与订阅索引的
    // 显示名也可能不一致，仅靠 state 匹配会漏判，重复导入订阅就会产生
    // xxx.js / xxx-2.js 多组副本。改用批内索引（同批次只全目录扫描解析
    // 一次）找出归一化 ID 相同的文件，一次性合并成一个。
    final session = index ?? _PluginIdIndex(pluginsDir);
    final duplicates = List<File>.from(await session.duplicatesOf(id));

    if (duplicates.isNotEmpty) {
      // 版本校验（默认开启）：同 ID 插件来自不同订阅源时，旧版本不应覆盖
      // 已安装的新版本。开启「安装插件不校验版本」后始终以新内容覆盖。
      final skipVersionCheck =
          ref
              .read(settingsProvider)
              .valueOrNull
              ?.pluginInstallSkipVersionCheck ??
          false;
      if (!skipVersionCheck) {
        final existingVersion = await _latestExistingVersion(duplicates);
        final incomingVersion = metadata.version?.trim() ?? '';
        // 仅当两边都是可比较的数字版本时才判断「旧版本不覆盖」。
        // 描述性 version（部分 MusicFree 改造器插件写成人名/说明文案）
        // 无法比较，若参与校验会被折算成 0.0.0 而永远被跳过。
        if (existingVersion.isNotEmpty &&
            incomingVersion.isNotEmpty &&
            PluginMetadata.isComparableVersion(incomingVersion) &&
            PluginMetadata.isComparableVersion(existingVersion) &&
            PluginMetadata.compareVersions(incomingVersion, existingVersion) <
                0) {
          summary.skipped++;
          return false;
        }
      }
      return _mergeDuplicates(
        duplicates,
        script,
        origin,
        id,
        name,
        metadata,
        pluginsDir,
        prefs,
        summary,
        session,
        displayName: indexName.isNotEmpty ? name : null,
        kindHint: kindHint,
      );
    }

    final file = File(p.join(pluginsDir.path, '$id.js'));
    await file.writeAsString(script);
    session.register(id, file);
    final enabled = (prefs.getStringList(_enabledKey) ?? const []).toSet()
      ..add(id);
    await prefs.setStringList(_enabledKey, enabled.toList());
    if (origin.startsWith('http://') || origin.startsWith('https://')) {
      final sources = _readSourceUrls(prefs)..[id] = origin;
      await prefs.setString(_sourceUrlsKey, jsonEncode(sources));
    }
    // 显示名覆盖表：订阅索引给的名字写入后，脚本被混淆/无元信息时也能
    // 显示正确名称。
    if (indexName.isNotEmpty) {
      await _saveDisplayName(prefs, id, name);
    }
    if (kindHint != null && kindHint.isNotEmpty) {
      await _savePluginKind(prefs, id, kindHint);
    }
    summary.installed++;
    // 星海格式插件在安装提示中标注，让用户知道这是聚合变体。
    summary.names.add(metadata.isStarSea ? '$name（星海）' : name);
    return true;
  }

  /// 取磁盘上某组同 ID 副本中最高的版本号（用于安装前的版本校验）。
  Future<String> _latestExistingVersion(List<File> duplicates) async {
    var latest = '';
    for (final file in duplicates) {
      try {
        final version = PluginMetadata.parse(
          await file.readAsString(),
        ).version?.trim();
        if (version == null || version.isEmpty) continue;
        if (latest.isEmpty ||
            PluginMetadata.compareVersions(version, latest) > 0) {
          latest = version;
        }
      } catch (_) {
        // 读取/解析失败的文件不参与版本比较。
      }
    }
    return latest;
  }

  /// 写入/覆盖插件显示名覆盖表（仅在订阅索引提供了显式名称时调用）。
  Future<void> _saveDisplayName(
    SharedPreferences prefs,
    String id,
    String name,
  ) async {
    final names = readPluginDisplayNames(prefs)..[id] = name;
    await prefs.setString(pluginDisplayNamesKey, jsonEncode(names));
  }

  /// 写入/覆盖插件来源标签表（仅多租户订阅源的专属脚本调用）。
  Future<void> _saveSourceLabel(
    SharedPreferences prefs,
    String id,
    String label,
  ) async {
    final labels = readPluginSourceLabels(prefs)..[id] = label;
    await prefs.setString(pluginSourceLabelsKey, jsonEncode(labels));
  }

  /// 写入/覆盖插件订阅类型表（仅在线导入时调用）。
  Future<void> _savePluginKind(
    SharedPreferences prefs,
    String id,
    String kind,
  ) async {
    final kinds = readPluginKinds(prefs)..[id] = kind;
    await prefs.setString(pluginKindsKey, jsonEncode(kinds));
  }

  /// 从订阅源响应推断插件类型提示。
  ///
  /// 实测三类源的差异：
  /// - MusicFree 索引：`{plugins:[{name,url,version}]}`（部分含 desc）；
  /// - BakaMusic 订阅：同为 `{plugins:[...]}`，但额外带 `yourinfo`
  ///   （{ip,ua}）字段，URL 亦常为 `subscription.json`；
  /// - 洛雪源：返回**纯 JS 脚本**（非 JSON），由脚本内容判定，无提示。
  ///
  /// BakaMusic 与 MusicFree 插件脚本同构，内容层无法可靠区分，故用订阅
  /// 结构判定；无法判定时归 MusicFree（默认家族）。
  String _subscriptionKindHint(String url, Object? decoded) {
    final lower = url.toLowerCase();
    if (lower.contains('baka') || lower.contains('subscription.json')) {
      return pluginKindBaka;
    }
    // 已知 BakaMusic 域名（music.cwo.cc.cd / bakp.netlify.app /
    // animemusic.bzxhkj.com/baka）的索引，即使文件名不是 subscription.json
    // 也判 Baka——否则这类订阅只能靠「当前分栏」兜底，粘贴位置一变就归错。
    if (PluginMetadata.isBakaSourceUrl(url)) {
      return pluginKindBaka;
    }
    if (decoded is Map && decoded.containsKey('yourinfo')) {
      return pluginKindBaka;
    }
    return pluginKindMusicFree;
  }

  /// 从插件脚本 URL 提取多租户订阅源标识（`?source=ikun`）。
  ///
  /// BakaMusic 的多租户订阅（如 music.cwo.cc.cd）对**同一插件**按 source
  /// 发放不同授权的脚本：文件名相同（qq.js）、`platform` 相同（QQ音乐），
  /// 只有内嵌的授权不同。不带上 source 就会算出同一个插件 ID，导入第二个
  /// 订阅时把第一个覆盖掉（IKUN 与聆澜只能留下最后一个）。
  static String _subscriptionSourceTag(String url) {
    final uri = Uri.tryParse(url.trim());
    return uri?.queryParameters['source']?.trim() ?? '';
  }

  /// 多租户订阅源标识的展示名：已知来源给出规范写法，未知来源原样展示。
  static String _subscriptionSourceLabel(String source) {
    final trimmed = source.trim();
    return switch (trimmed.toLowerCase()) {
      'ikun' => 'IKUN',
      'linglan' => '聆澜',
      _ => trimmed,
    };
  }

  /// 把磁盘上已存在的同 ID 插件副本合并为一个文件：主文件以新脚本
  /// 覆盖，其余后缀变体删除，启用状态/订阅来源/用户变量/排序等偏好
  /// 一并迁移到主 ID 上。内容与磁盘一致时仅清理多余副本并跳过安装。
  Future<bool> _mergeDuplicates(
    List<File> duplicates,
    String script,
    String origin,
    String id,
    String name,
    PluginMetadata metadata,
    Directory pluginsDir,
    SharedPreferences prefs,
    _MutableInstallSummary summary,
    _PluginIdIndex session, {
    String? displayName,
    String? kindHint,
  }) async {
    final primaryPath = p.join(pluginsDir.path, '$id.js');
    final primaryExists = duplicates.any((file) => file.path == primaryPath);
    // 无论主文件是否在副本集合里，最终都归一到 $id.js 承载新脚本。
    final removedIds = duplicates
        .where((file) => file.path != primaryPath)
        .map((file) => p.basenameWithoutExtension(file.path))
        .toSet();
    if (!primaryExists) {
      // 主文件缺失时第一个副本的偏好也要迁移到主 ID。
      removedIds.add(p.basenameWithoutExtension(duplicates.first.path));
    }

    final enabled = (prefs.getStringList(_enabledKey) ?? const []).toSet();
    final wasEnabled = enabled.contains(id) || removedIds.any(enabled.contains);
    enabled.removeAll(removedIds);
    if (wasEnabled) enabled.add(id);
    await prefs.setStringList(_enabledKey, enabled.toList());

    final sources = _readSourceUrls(prefs);
    for (final removedId in removedIds) {
      final value = sources.remove(removedId);
      if (value != null && sources[id]?.isNotEmpty != true) {
        sources[id] = value;
      }
    }
    if (origin.startsWith('http://') || origin.startsWith('https://')) {
      sources[id] = origin;
    }
    await prefs.setString(_sourceUrlsKey, jsonEncode(sources));

    final variables = readPluginUserVariables(prefs);
    var variablesChanged = false;
    for (final removedId in removedIds) {
      final value = variables.remove(removedId);
      if (value != null && !variables.containsKey(id)) {
        variables[id] = value;
        variablesChanged = true;
      }
    }
    if (variablesChanged) {
      await prefs.setString(pluginUserVariablesKey, jsonEncode(variables));
    }

    final order = prefs.getStringList(pluginOrderKey);
    if (order != null && order.any(removedIds.contains)) {
      await prefs.setStringList(
        pluginOrderKey,
        order.where((item) => !removedIds.contains(item)).toList(),
      );
    }

    // 显示名覆盖表：旧 ID 的名称迁移到主 ID，订阅索引给的新名称优先。
    final names = readPluginDisplayNames(prefs);
    var namesChanged = false;
    for (final removedId in removedIds) {
      final value = names.remove(removedId);
      if (value != null && !names.containsKey(id)) {
        names[id] = value;
        namesChanged = true;
      }
    }
    final overrideName = displayName?.trim() ?? '';
    if (overrideName.isNotEmpty && names[id] != overrideName) {
      names[id] = overrideName;
      namesChanged = true;
    }
    if (namesChanged) {
      await prefs.setString(pluginDisplayNamesKey, jsonEncode(names));
    }

    // 订阅类型表：旧 ID 的类型迁移到主 ID，本次导入的来源类型优先。
    final kinds = readPluginKinds(prefs);
    var kindsChanged = false;
    for (final removedId in removedIds) {
      final value = kinds.remove(removedId);
      if (value != null && !kinds.containsKey(id)) {
        kinds[id] = value;
        kindsChanged = true;
      }
    }
    final hint = kindHint?.trim() ?? '';
    if (hint.isNotEmpty && kinds[id] != hint) {
      kinds[id] = hint;
      kindsChanged = true;
    }
    if (kindsChanged) {
      await prefs.setString(pluginKindsKey, jsonEncode(kinds));
    }

    // 来源标签表：旧 ID 的标签迁移到主 ID（本次导入已按新 ID 写入来源，
    // 存在时不覆盖）。
    final labels = readPluginSourceLabels(prefs);
    var labelsChanged = false;
    for (final removedId in removedIds) {
      final value = labels.remove(removedId);
      if (value != null && !labels.containsKey(id)) {
        labels[id] = value;
        labelsChanged = true;
      }
    }
    if (labelsChanged) {
      await prefs.setString(pluginSourceLabelsKey, jsonEncode(labels));
    }

    final removedFiles = <File>[];
    for (final file in duplicates) {
      if (file.path == primaryPath) continue;
      try {
        await file.delete();
        removedFiles.add(file);
      } catch (_) {
        // 删除失败时以刷新后的实际列表为准，不阻断安装。
      }
    }
    session.unregister(removedFiles);

    // 旧 ID 变体已删除、偏好已迁移到新 ID，存量歌曲数据（歌单/收藏/
    // 最近播放里的旧 ID 引用）必须一并迁移，否则旧歌单全部断链。
    await _migrateRenamedPluginReferences(removedIds, id);

    final primary = File(primaryPath);
    if (primary.existsSync() && await primary.readAsString() == script) {
      session.register(id, primary);
      summary.skipped++;
      return false;
    }
    await primary.writeAsString(script);
    session.register(id, primary);
    summary.installed++;
    summary.names.add(metadata.isStarSea ? '$name（星海）' : name);
    return true;
  }

  /// 插件 ID 漂移时迁移存量歌曲数据：旧 ID 文件被合并删除后，歌单、
  /// 收藏与最近播放里 `plugin://旧ID/` 路径和 pluginId 字段会全部
  /// 断链（订阅插件更新后 name 加上赞助后缀、旧版本回退哈希 ID 等
  /// 都会造成 ID 变化）。迁移完成后重建相关 provider 的内存快照。
  Future<void> _migrateRenamedPluginReferences(
    Set<String> removedIds,
    String id,
  ) async {
    if (removedIds.isEmpty) return;
    try {
      final migrated = await migratePluginReferences({
        for (final removedId in removedIds) removedId: id,
      });
      if (migrated > 0) {
        ref.invalidate(playlistsProvider);
        ref.invalidate(favoritesProvider);
        ref.invalidate(recentSongsProvider);
      }
    } catch (_) {
      // 迁移失败不阻断安装；下次合并同一插件时会再次尝试。
    }
  }

  /// [kindHint] 为安装时用户所在分栏的分类标识：单文件插件（直链/本地）
  /// 的脚本内容无法区分 BakaMusic 与 MusicFree（多契约插件字段完全重叠），
  /// 只能靠用户所在分栏兜底，否则一律落进 MusicFree 分栏。
  Future<_InstallSummary> installFromUrl(String url, {String? kindHint}) async {
    final summary = _MutableInstallSummary();
    final content = await _downloadText(url);
    final trimmed = content.trim();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        final decoded = jsonDecode(trimmed);
        final dynamic rawItems = decoded is List
            ? decoded
            : decoded is Map<String, dynamic>
            ? (decoded['plugins'] ?? decoded['plugin'])
            : null;
        if (rawItems is List && rawItems.isNotEmpty) {
          final base = Uri.parse(url);
          // 订阅源类型提示：Baka 订阅索引与 MusicFree 索引结构相同，
          // 靠索引 URL（含 baka/subscription.json 或已知 Baka 域名）与
          // 索引内的 yourinfo 字段把整批插件归入正确分栏。
          //
          // 订阅索引的家族由索引自身决定，**不采用「当前分栏」提示**：
          // 分栏只说明粘贴订阅地址时页面停在哪儿（插件管理页会默认停在
          // 首个非空分栏），与索引内容无关。实测把 MusicFree 订阅地址粘在
          // BakaMusic 分栏时，整批 MusicFree 插件会被打上 baka 提示并长期
          // 留在 BakaMusic 分栏；提示还会在后续每次导入时继续沿用。
          // （单文件插件无结构可依，仍按所在分栏兜底，见下方分支。）
          final indexKind = _subscriptionKindHint(url, decoded);
          // 整批共用一份目录索引，且每装完一个让出一次事件循环。
          final index = await _newInstallIndex();
          for (final raw in rawItems.take(_maxIndexItems)) {
            if (raw is! Map) continue;
            final item = Map<String, dynamic>.from(raw);
            final rawUrl = item['url']?.toString().trim() ?? '';
            if (rawUrl.isEmpty) continue;
            final pluginUrl = base.resolve(rawUrl).toString();
            try {
              final (script, effectiveUrl) = await _downloadIndexPlugin(
                pluginUrl,
                base,
              );
              // 单条插件脚本托管在已知 Baka 域名时以 Baka 为准
              // （MusicFree 索引里也可能挂 baka 系插件）。
              final pluginKind =
                  indexKind == pluginKindBaka ||
                      PluginMetadata.isBakaSourceUrl(effectiveUrl)
                  ? pluginKindBaka
                  : indexKind;
              await _persistScript(
                script,
                effectiveUrl,
                summary,
                displayName: item['name']?.toString(),
                kindHint: pluginKind,
                // 多租户订阅：按脚本 URL 的 source 区分同一插件的不同授权，
                // 避免 IKUN / 聆澜 等来源互相覆盖。
                subscriptionSource: _subscriptionSourceTag(effectiveUrl),
                index: index,
              );
            } catch (error) {
              summary.failed++;
              summary.errors.add('${item['name'] ?? pluginUrl}：$error');
            }
            await _yieldToUi();
          }
          state = AsyncData(await _load());
          ref.invalidate(enabledMusicPluginsProvider);
          return summary.freeze();
        }
      } catch (_) {
        // 不是插件索引时，继续按单个脚本处理并给出准确的格式错误。
      }
    }

    try {
      // 直链也可能是多租户订阅的源专属脚本（带 ?source=），同样带上来源
      // 标识，保证与订阅批量安装算出的 ID 一致、互不覆盖。
      await _persistScript(
        content,
        url,
        summary,
        kindHint: kindHint,
        subscriptionSource: _subscriptionSourceTag(url),
      );
    } catch (error) {
      summary.failed++;
      summary.errors.add(error.toString());
    }
    state = AsyncData(await _load());
    ref.invalidate(enabledMusicPluginsProvider);
    return summary.freeze();
  }

  Future<_InstallSummary> importPlugin({String? kindHint}) async {
    final result = await FilePicker.platform.pickFiles(
      // 不用 FileType.custom + allowedExtensions：js 的 MIME 类型
      // （text/javascript）在华为/荣耀等魔改 ROM 的文件选择器上
      // 不被支持，直接抛 "Unsupported filter"。改为不限制类型，
      // 选中后在下方按扩展名自行校验。
      type: FileType.any,
      // 支持一次选多个插件脚本批量导入。
      allowMultiple: true,
      // Android 的 Storage Access Framework 对外部文件有时不会返回可直接
      // 读取的 path，只返回文件内容；同时请求 bytes 兼容这类文件选择结果。
      withData: true,
    );
    final files = result?.files ?? const <PlatformFile>[];
    final summary = _MutableInstallSummary();
    // 整批共用一份目录索引，且每装完一个让出一次事件循环（批量选几十个
    // 脚本时避免主线程长时间独占导致无响应/闪退）。
    final index = files.isEmpty ? null : await _newInstallIndex();
    for (final file in files) {
      try {
        final extension = p.extension(file.name).toLowerCase();
        if (extension != '.js') {
          throw Exception('仅支持 .js 插件脚本，所选为 $file.name');
        }
        final path = file.path;
        final script = file.bytes != null
            ? utf8.decode(file.bytes!, allowMalformed: true)
            : path != null
            ? await File(path).readAsString()
            : '';
        if (script.isEmpty) {
          throw Exception('无法读取所选插件文件，请重新选择');
        }
        // path 为空时使用文件名作为来源，保证插件 ID 仍能稳定生成。
        await _persistScript(
          script,
          path ?? file.name,
          summary,
          kindHint: kindHint,
          index: index,
        );
      } catch (error) {
        summary.failed++;
        summary.errors.add('${file.name}：$error');
      }
      await _yieldToUi();
    }
    if (files.isEmpty) {
      return const _InstallSummary(
        installed: 0,
        skipped: 0,
        failed: 0,
        names: [],
        errors: [],
      );
    }
    state = AsyncData(await _load());
    ref.invalidate(enabledMusicPluginsProvider);
    return summary.freeze();
  }

  Future<void> toggle(_PluginInfo plugin, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = (prefs.getStringList(_enabledKey) ?? const []).toSet();
    value ? enabled.add(plugin.id) : enabled.remove(plugin.id);
    await prefs.setStringList(_enabledKey, enabled.toList());
    state = AsyncData(await _load());
    ref.invalidate(enabledMusicPluginsProvider);
  }

  /// 拖拽排序：同步更新列表并持久化顺序，该顺序即搜索页插件 Tab 优先级。
  /// 注意：onReorderItem 回调的 newIndex 已为移除 oldIndex 项后的目标位置，
  /// 无需手动减一。
  Future<void> reorder(int oldIndex, int newIndex) async {
    final items = [...?state.valueOrNull];
    if (oldIndex < 0 || oldIndex >= items.length) return;
    if (newIndex < 0) newIndex = 0;
    if (newIndex > items.length) newIndex = items.length;
    if (newIndex == oldIndex) return;
    final item = items.removeAt(oldIndex);
    items.insert(newIndex, item);
    await applyOrder(items);
  }

  /// 按给定顺序整体保存（分页 Tab 内拖拽时由调用方换算好全量顺序）。
  Future<void> applyOrder(List<_PluginInfo> ordered) async {
    state = AsyncData(ordered);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      pluginOrderKey,
      ordered.map((plugin) => plugin.id).toList(),
    );
    ref.invalidate(enabledMusicPluginsProvider);
  }

  /// 重新读取插件目录与分类表（手动更改分类后刷新列表）。
  Future<void> reload() async {
    state = AsyncData(await _load());
  }

  /// 保存插件用户变量并让运行时按新值重新加载插件。
  Future<void> saveUserVariables(
    _PluginInfo plugin,
    Map<String, String> values,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = readPluginUserVariables(prefs);
    // 只保留插件当前声明的变量键，卸载或插件更新后消失的键会被清理。
    final declared = plugin.userVariables.map((v) => v.key).toSet();
    final filtered = {
      for (final entry in values.entries)
        if (declared.contains(entry.key) && entry.value.isNotEmpty)
          entry.key: entry.value,
    };
    if (filtered.isEmpty) {
      stored.remove(plugin.id);
    } else {
      stored[plugin.id] = filtered;
    }
    await prefs.setString(pluginUserVariablesKey, jsonEncode(stored));
    // 已加载的插件实例持有旧的 env.userVariables，必须让运行时重建。
    ref.invalidate(pluginRuntimeProvider);
    ref.invalidate(enabledMusicPluginsProvider);
  }

  Future<_InstallSummary> updatePlugin(_PluginInfo plugin) async {
    final url = plugin.sourceUrl;
    if (url == null || url.isEmpty) throw Exception('本地导入的插件没有在线更新地址');
    return installFromUrl(url);
  }

  /// 一键更新全部订阅插件：逐个从安装时记录的来源地址重新拉取安装，
  /// 内容未变的跳过，单个失败不中断其余更新。与单曲更新一致走
  /// _persistScript 的去重合并链路（含偏好与歌单引用迁移）。
  Future<_InstallSummary> updateAll() async {
    final summary = _MutableInstallSummary();
    final online = (state.valueOrNull ?? const <_PluginInfo>[])
        .where((plugin) => plugin.isOnline)
        .toList();
    // 与批量安装一致：整批共用一份目录索引，逐个之间让出事件循环。
    final index = await _newInstallIndex();
    for (final plugin in online) {
      final url = plugin.sourceUrl!.trim();
      try {
        final content = await _downloadText(url);
        // 不传 displayName：保留已存在的显示名覆盖，新脚本的名称由元数据
        // 决定（若插件来源后来改名，ID 漂移由去重合并链路负责迁移）。
        await _persistScript(content, url, summary, index: index);
      } catch (error) {
        summary.failed++;
        summary.errors.add('${plugin.name}：$error');
      }
      await _yieldToUi();
    }
    state = AsyncData(await _load());
    ref.invalidate(enabledMusicPluginsProvider);
    return summary.freeze();
  }

  Future<void> remove(_PluginInfo plugin) async {
    await removeMany([plugin]);
  }

  Future<void> removeMany(Iterable<_PluginInfo> plugins) async {
    final targets = plugins.toList(growable: false);
    if (targets.isEmpty) return;
    for (final plugin in targets) {
      try {
        final file = File(plugin.path);
        if (file.existsSync()) await file.delete();
      } catch (_) {
        // 继续删除其它插件，最后以刷新后的实际列表为准。
      }
    }
    final prefs = await SharedPreferences.getInstance();
    final ids = targets.map((plugin) => plugin.id).toSet();
    final enabled = (prefs.getStringList(_enabledKey) ?? const []).toSet()
      ..removeAll(ids);
    await prefs.setStringList(_enabledKey, enabled.toList());
    final sources = _readSourceUrls(prefs);
    for (final id in ids) {
      sources.remove(id);
    }
    await prefs.setString(_sourceUrlsKey, jsonEncode(sources));
    final variables = readPluginUserVariables(prefs);
    if (variables.isNotEmpty) {
      variables.removeWhere((id, _) => ids.contains(id));
      await prefs.setString(pluginUserVariablesKey, jsonEncode(variables));
    }
    // 显示名覆盖表随插件卸载清理，避免重装同 ID 时残留旧名称。
    final names = readPluginDisplayNames(prefs);
    if (names.isNotEmpty && names.keys.any(ids.contains)) {
      names.removeWhere((id, _) => ids.contains(id));
      await prefs.setString(pluginDisplayNamesKey, jsonEncode(names));
    }
    // 来源标签表同理随卸载清理。
    final labels = readPluginSourceLabels(prefs);
    if (labels.isNotEmpty && labels.keys.any(ids.contains)) {
      labels.removeWhere((id, _) => ids.contains(id));
      await prefs.setString(pluginSourceLabelsKey, jsonEncode(labels));
    }
    state = AsyncData(await _load());
    ref.invalidate(enabledMusicPluginsProvider);
  }

  Future<void> removeAll() async {
    await removeMany(state.valueOrNull ?? const []);
  }
}

final _pluginsProvider =
    AsyncNotifierProvider<_PluginsNotifier, List<_PluginInfo>>(
      _PluginsNotifier.new,
    );

class PluginsPage extends ConsumerStatefulWidget {
  const PluginsPage({super.key, this.showSidebarButton = false});

  final bool showSidebarButton;

  @override
  ConsumerState<PluginsPage> createState() => _PluginsPageState();
}

class _PluginsPageState extends ConsumerState<PluginsPage> {
  final TextEditingController _installUrlController = TextEditingController();
  bool _busy = false;
  bool _selectionMode = false;
  final Set<String> _selectedIds = <String>{};

  /// 分页 Tab：0 = 普通插件（MusicFree/星海），1 = LX 音源。
  int _tabIndex = 0;

  @override
  void dispose() {
    _installUrlController.dispose();
    super.dispose();
  }

  void _showResult(_InstallSummary result) {
    if (!mounted ||
        (result.installed == 0 && result.skipped == 0 && result.failed == 0)) {
      return;
    }
    final details = result.errors.isEmpty
        ? ''
        : '\n${result.errors.take(2).join('\n')}';
    XyNotice.show(
      context,
      message: '${result.message}$details',
      type: result.errors.isEmpty ? XyNoticeType.success : XyNoticeType.warning,
    );
  }

  Future<void> _importLocal() async {
    setState(() => _busy = true);
    try {
      _showResult(
        await ref
            .read(_pluginsProvider.notifier)
            .importPlugin(kindHint: _currentKindHint()),
      );
    } catch (error) {
      // 文件选择器、系统存储权限或插件解析失败都不能静默吞掉，
      // 否则用户点击“本地导入”后看起来像按钮没有反应。
      if (mounted) {
        XyNotice.show(
          context,
          message: '本地导入失败：$error',
          type: XyNoticeType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _installFromUrl([String? kindHint]) async {
    final controller = _installUrlController..clear();
    final url = await showDialog<String>(
      context: context,
      useSafeArea: true,
      builder: (sheetContext) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420, maxHeight: 560),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: Theme.of(
                          sheetContext,
                        ).colorScheme.primary.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: Icon(
                        Icons.language_rounded,
                        color: Theme.of(sheetContext).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 11),
                    const Expanded(
                      child: Text(
                        '从网络安装插件',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.pop(sheetContext),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  '支持单个 JS 插件直链，以及包含 plugins 数组的 JSON 插件索引。',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: controller,
                  autofocus: true,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: '插件地址',
                    hintText: 'https://example.com/plugin.js',
                    prefixIcon: Icon(Icons.link_rounded),
                  ),
                  onSubmitted: (value) => Navigator.pop(sheetContext, value),
                ),
                const SizedBox(height: 12),
                const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 17,
                      color: Color(0xFFEC9A29),
                    ),
                    SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        '插件拥有网络访问能力，请只安装你信任的来源。',
                        style: TextStyle(
                          fontSize: 11,
                          color: Color(0xFF9A6A29),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(sheetContext),
                        child: const Text('取消'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: FilledButton.icon(
                        onPressed: () =>
                            Navigator.pop(sheetContext, controller.text.trim()),
                        icon: const Icon(Icons.download_rounded),
                        label: const Text('下载并安装'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (url == null || url.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      final result = await ref
          .read(_pluginsProvider.notifier)
          .installFromUrl(url, kindHint: kindHint);
      _showResult(result);
    } catch (error) {
      if (mounted) {
        XyNotice.show(
          context,
          message: '安装失败：$error',
          type: XyNoticeType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _update(_PluginInfo plugin) async {
    setState(() => _busy = true);
    try {
      _showResult(
        await ref.read(_pluginsProvider.notifier).updatePlugin(plugin),
      );
    } catch (error) {
      if (mounted) {
        XyNotice.show(context, message: '$error', type: XyNoticeType.error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 一键更新全部订阅插件：逐个从来源地址重新拉取，内容未变的跳过。
  Future<void> _updateAll() async {
    if (_busy) return;
    final onlineCount =
        ref.read(_pluginsProvider).valueOrNull
            ?.where((plugin) => plugin.isOnline)
            .length ??
        0;
    if (onlineCount == 0) {
      XyNotice.show(
        context,
        message: '没有订阅插件可更新',
        type: XyNoticeType.warning,
      );
      return;
    }
    setState(() => _busy = true);
    try {
      _showResult(await ref.read(_pluginsProvider.notifier).updateAll());
    } catch (error) {
      if (mounted) {
        XyNotice.show(context, message: '$error', type: XyNoticeType.error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showPluginInfo(_PluginInfo plugin) async {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('插件信息'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _PluginInfoRow(label: '名称', value: plugin.name),
              _PluginInfoRow(
                label: '格式',
                value: plugin.isStarSea
                    ? '星海（聚合来源标记 _src，一次搜索聚合多平台）'
                    : 'MusicFree 兼容',
              ),
              _PluginInfoRow(label: '作者', value: _displayValue(plugin.author)),
              _PluginInfoRow(label: '版本', value: plugin.version),
              _PluginInfoRow(
                label: '分类',
                value: _kindLabel(plugin.kind),
              ),
              if (plugin.sourceLabel?.trim().isNotEmpty == true)
                _PluginInfoRow(
                  label: '来源',
                  value: plugin.sourceLabel!.trim(),
                ),
              _PluginInfoRow(label: '备注', value: _displayValue(plugin.remark)),
              if (plugin.isOnline) ...[
                const SizedBox(height: 4),
                Text('导入链接', style: TextStyle(fontSize: 12, color: muted)),
                const SizedBox(height: 4),
                SelectableText(
                  plugin.sourceUrl!.trim(),
                  style: TextStyle(
                    fontSize: 13,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              // 先关闭信息弹窗，再弹分类选择，避免两个弹窗叠在一起。
              Navigator.pop(dialogContext);
              _changePluginKind(plugin);
            },
            child: const Text('更改分类'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  static String _displayValue(String? value) {
    final text = value?.trim() ?? '';
    return text.isEmpty ? '暂无' : text;
  }

  Future<void> _showUserVariables(_PluginInfo plugin) async {
    final variables = plugin.userVariables;
    if (variables.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final saved = readPluginUserVariables(prefs)[plugin.id] ?? const {};
    final controllers = {
      for (final variable in variables)
        variable.key: TextEditingController(text: saved[variable.key] ?? ''),
    };
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('用户变量'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${plugin.name} 声明了以下变量，填写后插件可通过 env.getUserVariables() 读取。',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(dialogContext).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 14),
              for (final variable in variables) ...[
                Text(
                  variable.displayName,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (variable.hint?.isNotEmpty == true) ...[
                  const SizedBox(height: 2),
                  Text(
                    variable.hint!,
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(
                        dialogContext,
                      ).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 6),
                TextField(
                  controller: controllers[variable.key],
                  decoration: InputDecoration(
                    isDense: true,
                    border: const OutlineInputBorder(),
                    hintText: variable.hint ?? '请输入 ${variable.displayName}',
                    suffixIcon: ValueListenableBuilder<TextEditingValue>(
                      valueListenable: controllers[variable.key]!,
                      builder: (context, value, _) => value.text.isEmpty
                          ? const SizedBox.shrink()
                          : IconButton(
                              icon: const Icon(Icons.close_rounded, size: 18),
                              onPressed: () =>
                                  controllers[variable.key]!.clear(),
                            ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(_pluginsProvider.notifier).saveUserVariables(plugin, {
      for (final variable in variables)
        variable.key: controllers[variable.key]!.text.trim(),
    });
    if (mounted) {
      XyNotice.show(
        context,
        message: '已保存 ${plugin.name} 的用户变量',
        type: XyNoticeType.success,
      );
    }
  }

  Future<void> _remove(_PluginInfo plugin) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除插件'),
        content: Text('确定删除“${plugin.name}”吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(_pluginsProvider.notifier).remove(plugin);
    }
  }

  Future<void> _removeSelected(List<_PluginInfo> items) async {
    final selected = items
        .where((plugin) => _selectedIds.contains(plugin.id))
        .toList();
    if (selected.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('批量删除插件'),
        content: Text('确定删除选中的 ${selected.length} 个插件吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(_pluginsProvider.notifier).removeMany(selected);
      if (mounted) {
        setState(() {
          _selectedIds.clear();
          _selectionMode = false;
        });
        XyNotice.show(context, message: '已删除 ${selected.length} 个插件');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeAll(List<_PluginInfo> items) async {
    if (items.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除全部插件'),
        content: Text('确定删除全部 ${items.length} 个插件吗？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('全部删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(_pluginsProvider.notifier).removeAll();
      if (mounted) {
        setState(() {
          _selectedIds.clear();
          _selectionMode = false;
        });
        XyNotice.show(context, message: '已删除全部插件');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final plugins = ref.watch(_pluginsProvider);
    final sidebarOnRight = ref.watch(
      settingsProvider.select(
        (value) => value.valueOrNull?.sidebarPosition == SidebarPosition.right,
      ),
    );
    // 当前播放歌曲的来源插件，用于卡片上的「播放中」解析指示。
    final playingPluginId = ref.watch(
      playerProvider.select((state) => state.current?.pluginId),
    );
    // 订阅插件数：决定一键更新按钮是否可用。
    final onlineCount =
        plugins.valueOrNull?.where((plugin) => plugin.isOnline).length ?? 0;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.showSidebarButton || !sidebarOnRight,
        leading: widget.showSidebarButton && !sidebarOnRight
            ? const AppSidebarMenuButton()
            : widget.showSidebarButton
            ? null
            : const BackButton(),
        title: const Text('插件管理'),
        actions: [
          IconButton(
            tooltip: _busy ? '更新中...' : '一键更新订阅插件',
            onPressed: _busy || onlineCount == 0 ? null : _updateAll,
            icon: _busy
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cloud_sync_rounded),
          ),
          if (widget.showSidebarButton && sidebarOnRight)
            const AppSidebarMenuButton(),
        ],
      ),
      body: XyPageBackground(
        child: plugins.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(child: Text('插件加载失败：$error')),
          data: (items) {
            _selectedIds.removeWhere(
              (id) => !items.any((plugin) => plugin.id == id),
            );
            // 各分类分页计数：BakaMusic/MusicFree/LX/animemusic/其他。
            final kindCounts = {
              for (final kind in _PluginKind.values)
                kind: items.where((item) => item.kind == kind).length,
            };
            // 当前分类为空时回退到第一个非空分类，避免停留空页。
            var tabIndex = _tabIndex;
            if (kindCounts[_PluginKind.values[tabIndex]] == 0) {
              final fallback = _PluginKind.values
                  .where((kind) => kindCounts[kind]! > 0)
                  .firstOrNull;
              if (fallback != null) {
                tabIndex = _PluginKind.values.indexOf(fallback);
              }
            }
            // 只显示有插件的分类；全部为空（首次安装、清空插件）时保留
            // 完整分类展示，避免页签整体消失。
            final nonEmptyKinds = _PluginKind.values
                .where((kind) => kindCounts[kind]! > 0)
                .toList();
            final shownKinds = nonEmptyKinds.isEmpty
                ? _PluginKind.values
                : nonEmptyKinds;
            final visible = items
                .where((item) => item.kind == _PluginKind.values[tabIndex])
                .toList();
            return Stack(
              children: [
                CustomScrollView(
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      sliver: SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const _PluginHeroBanner(),
                            const SizedBox(height: 10),
                            const _SecurityNotice(),
                            const SizedBox(height: 14),
                            _InstallPanel(
                              busy: _busy,
                              onOnline: () =>
                                  _installFromUrl(_currentKindHint()),
                              onLocal: _importLocal,
                              skipVersionCheck: ref.watch(
                                settingsProvider.select(
                                  (value) =>
                                      value
                                          .valueOrNull
                                          ?.pluginInstallSkipVersionCheck ??
                                      false,
                                ),
                              ),
                              onSkipVersionCheckChanged: (value) => ref
                                  .read(settingsProvider.notifier)
                                  .setPluginInstallSkipVersionCheck(value),
                            ),
                            const SizedBox(height: 22),
                            Row(
                              children: [
                                Expanded(
                                  // 分类页签横向排布，窄屏放不下时滚动；
                                  // 空分类不显示（见 shownKinds）。
                                  child: SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    child: SegmentedButton<int>(
                                      segments: [
                                        for (final kind in shownKinds)
                                          ButtonSegment(
                                            value: _PluginKind.values.indexOf(
                                              kind,
                                            ),
                                            icon: Icon(
                                              _kindIcon(kind),
                                              size: 16,
                                            ),
                                            label: Text(
                                              '${_kindLabel(kind)} ${kindCounts[kind]}',
                                            ),
                                          ),
                                      ],
                                      selected: {tabIndex},
                                      onSelectionChanged: _busy
                                          ? null
                                          : (selection) => setState(() {
                                              _tabIndex = selection.first;
                                            }),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            if (visible.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  OutlinedButton.icon(
                                    onPressed: _busy
                                        ? null
                                        : () => setState(() {
                                            _selectionMode = !_selectionMode;
                                            if (!_selectionMode) {
                                              _selectedIds.clear();
                                            }
                                          }),
                                    icon: Icon(
                                      _selectionMode
                                          ? Icons.close_rounded
                                          : Icons.checklist_rounded,
                                    ),
                                    label: Text(
                                      _selectionMode ? '退出选择' : '批量管理',
                                    ),
                                  ),
                                  if (_selectionMode)
                                    OutlinedButton.icon(
                                      onPressed: _busy
                                          ? null
                                          : () => setState(() {
                                              final visibleIds = visible
                                                  .map((plugin) => plugin.id)
                                                  .toSet();
                                              if (visibleIds.every(
                                                _selectedIds.contains,
                                              )) {
                                                _selectedIds.removeAll(
                                                  visibleIds,
                                                );
                                              } else {
                                                _selectedIds.addAll(visibleIds);
                                              }
                                            }),
                                      icon: const Icon(
                                        Icons.select_all_rounded,
                                      ),
                                      label: const Text('全选'),
                                    ),
                                  if (_selectionMode)
                                    FilledButton.icon(
                                      onPressed: _busy || _selectedIds.isEmpty
                                          ? null
                                          : () => _removeSelected(items),
                                      icon: const Icon(
                                        Icons.delete_outline_rounded,
                                      ),
                                      label: Text(
                                        '删除选中（${_selectedIds.length}）',
                                      ),
                                    ),
                                  OutlinedButton.icon(
                                    onPressed: _busy
                                        ? null
                                        : () => _removeAll(items),
                                    icon: const Icon(
                                      Icons.delete_sweep_outlined,
                                    ),
                                    label: const Text('删除全部'),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '拖动插件左侧的手柄排序，从上到下即搜索页插件 Tab 的优先级。',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                            const SizedBox(height: 12),
                          ],
                        ),
                      ),
                    ),
                    if (visible.isEmpty)
                      SliverPadding(
                        // 读取注入的悬浮元素遮挡高度（底栏/迷你播放栏），
                        // 最后一个插件不被悬浮元素盖住。
                        padding: EdgeInsets.fromLTRB(
                          16,
                          0,
                          16,
                          MediaQuery.paddingOf(context).bottom + 24,
                        ),
                        sliver: SliverToBoxAdapter(
                          child: _EmptyPlugins(
                            onOnline: () =>
                                _installFromUrl(_currentKindHint()),
                            onLocal: _importLocal,
                            hint: items.isEmpty
                                ? '还没有安装插件'
                                : '还没有${_kindLabel(_PluginKind.values[tabIndex])}音源',
                            actionLabel: items.isEmpty ? '输入插件地址' : '安装到当前分类',
                          ),
                        ),
                      )
                    else
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(
                          16,
                          0,
                          16,
                          MediaQuery.paddingOf(context).bottom + 24,
                        ),
                        sliver: SliverReorderableList(
                          onReorderItem: (oldIndex, newIndex) =>
                              _reorderInTab(items, visible, oldIndex, newIndex),
                          itemCount: visible.length,
                          itemBuilder: (context, index) {
                            final plugin = visible[index];
                            return Padding(
                              key: ValueKey(plugin.id),
                              padding: EdgeInsets.only(
                                bottom: index == visible.length - 1 ? 0 : 10,
                              ),
                              // 批量选择模式下不显示拖拽手柄，避免与勾选冲突。
                              child: _PluginCard(
                                plugin: plugin,
                                dragIndex: _selectionMode ? -1 : index,
                                busy: _busy,
                                selectable: _selectionMode,
                                selected: _selectedIds.contains(plugin.id),
                                isPlaying: playingPluginId == plugin.id,
                                onSelect: (value) => setState(() {
                                  value
                                      ? _selectedIds.add(plugin.id)
                                      : _selectedIds.remove(plugin.id);
                                }),
                                onToggle: (value) => ref
                                    .read(_pluginsProvider.notifier)
                                    .toggle(plugin, value),
                                onInfo: () => _showPluginInfo(plugin),
                                onUserVariables: plugin.userVariables.isEmpty
                                    ? null
                                    : () => _showUserVariables(plugin),
                                onUpdate: !plugin.isOnline
                                    ? null
                                    : () => _update(plugin),
                                onRemove: () => _remove(plugin),
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
                if (_busy)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    child: LinearProgressIndicator(
                      minHeight: 2,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 分页 Tab 内拖拽排序：先在当前分类子列表内完成移动，再把新顺序
  /// 回填到全量列表中同类插件占用的位置槽，最后整体持久化，保证四个
  /// Tab 的相对顺序互不干扰。
  void _reorderInTab(
    List<_PluginInfo> all,
    List<_PluginInfo> visible,
    int oldIndex,
    int newIndex,
  ) {
    if (oldIndex < 0 || oldIndex >= visible.length) return;
    if (newIndex < 0) newIndex = 0;
    if (newIndex > visible.length) newIndex = visible.length;
    if (newIndex == oldIndex) return;
    final moved = visible.removeAt(oldIndex);
    visible.insert(newIndex, moved);
    final positions = <int>[
      for (var i = 0; i < all.length; i++)
        if (all[i].kind == moved.kind) i,
    ];
    final merged = [...all];
    for (var v = 0; v < visible.length && v < positions.length; v++) {
      merged[positions[v]] = visible[v];
    }
    ref.read(_pluginsProvider.notifier).applyOrder(merged);
  }

  /// 分类显示名（空态文案用）。
  static String _kindLabel(_PluginKind kind) => switch (kind) {
    _PluginKind.baka => 'BakaMusic',
    _PluginKind.musicfree => 'MusicFree',
    _PluginKind.lx => 'LX',
    _PluginKind.animemusic => 'animemusic',
    _PluginKind.other => '其他',
  };

  /// 分类页签图标（与此前固定 ButtonSegment 的图标保持一致）。
  static IconData _kindIcon(_PluginKind kind) => switch (kind) {
    _PluginKind.baka => Icons.hub_rounded,
    _PluginKind.musicfree => Icons.extension_rounded,
    _PluginKind.lx => Icons.cable_rounded,
    _PluginKind.animemusic => Icons.cloud_rounded,
    _PluginKind.other => Icons.category_rounded,
  };

  /// 分栏分类对应的持久化标识（写入插件分类覆盖表用）。
  static String _kindKey(_PluginKind kind) => switch (kind) {
    _PluginKind.baka => pluginKindBaka,
    _PluginKind.musicfree => pluginKindMusicFree,
    _PluginKind.lx => pluginKindLx,
    _PluginKind.animemusic => pluginKindAnimemusic,
    _PluginKind.other => pluginKindOther,
  };

  /// 当前分栏的分类标识：单文件安装（直链/本地文件）无法从脚本内容区分
  /// BakaMusic 与 MusicFree，用用户所在分栏作为分类提示。
  String _currentKindHint() {
    final index = _tabIndex.clamp(0, _PluginKind.values.length - 1);
    return _kindKey(_PluginKind.values[index]);
  }

  /// 手动更改插件分类：多契约插件（同时兼容 BakaMusic/MusicFree/LX）
  /// 脚本内容完全重叠、自动识别无法可靠区分，提供手动归位入口。
  Future<void> _changePluginKind(_PluginInfo plugin) async {
    final chosen = await showDialog<_PluginKind>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text('${plugin.name} 的分类'),
        children: [
          for (final kind in _PluginKind.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, kind),
              child: Row(
                children: [
                  Icon(_kindIcon(kind), size: 20),
                  const SizedBox(width: 12),
                  Text(
                    _kindLabel(kind),
                    style: TextStyle(
                      fontWeight: kind == plugin.kind
                          ? FontWeight.w800
                          : FontWeight.w400,
                    ),
                  ),
                  if (kind == plugin.kind) ...[
                    const Spacer(),
                    const Icon(Icons.check_rounded, size: 18),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
    if (chosen == null || chosen == plugin.kind) return;
    final prefs = await SharedPreferences.getInstance();
    final kinds = readPluginKinds(prefs)..[plugin.id] = _kindKey(chosen);
    await prefs.setString(pluginKindsKey, jsonEncode(kinds));
    if (!mounted) return;
    await ref.read(_pluginsProvider.notifier).reload();
    ref.invalidate(enabledMusicPluginsProvider);
  }
}

class _SecurityNotice extends StatelessWidget {
  const _SecurityNotice();

  @override
  Widget build(BuildContext context) {
    return XyPanel(
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.security_rounded,
            size: 21,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '插件脚本可访问网络并参与在线音乐解析。关闭插件会保留文件，但不会将其列为启用来源。',
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InstallPanel extends StatelessWidget {
  const _InstallPanel({
    required this.busy,
    required this.onOnline,
    required this.onLocal,
    required this.skipVersionCheck,
    required this.onSkipVersionCheckChanged,
  });

  final bool busy;
  final VoidCallback onOnline;
  final VoidCallback onLocal;

  /// 安装插件不校验版本：开启后新内容始终覆盖已安装的同 ID 插件。
  final bool skipVersionCheck;
  final ValueChanged<bool> onSkipVersionCheckChanged;

  @override
  Widget build(BuildContext context) {
    return XyPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '安装插件',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 5),
          Text(
            '与电脑端一致，支持网络直链、JSON 插件索引和本地文件。'
            '单文件插件无法自动区分 BakaMusic/MusicFree，按当前分栏归入对应分类。',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: busy ? null : onOnline,
                  icon: const Icon(Icons.language_rounded),
                  label: const Text('在线安装'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: busy ? null : onLocal,
                  icon: const Icon(Icons.file_open_outlined),
                  label: const Text('本地导入'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // 关闭时（默认）同 ID 插件的新内容版本更低则不覆盖，避免多个
          // 订阅源互相覆盖；开启后始终以最新拉取的内容覆盖。
          SwitchListTile.adaptive(
            value: skipVersionCheck,
            onChanged: busy ? null : onSkipVersionCheckChanged,
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('安装插件不校验版本', style: TextStyle(fontSize: 14)),
            subtitle: Text(
              '开启后新内容始终覆盖同 ID 插件（可能被低版本订阅源覆盖）',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyPlugins extends StatelessWidget {
  const _EmptyPlugins({
    required this.onOnline,
    required this.onLocal,
    this.hint = '还没有安装插件',
    this.actionLabel = '输入插件地址',
  });

  final VoidCallback onOnline;
  final VoidCallback onLocal;

  /// 空态文案：整个插件目录为空与当前分页（普通插件/LX 音源）为空
  /// 提示不同。
  final String hint;
  final String actionLabel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          Icon(
            Icons.extension_off_outlined,
            size: 54,
            color: Theme.of(
              context,
            ).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(hint, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            '从网络地址或本地文件安装兼容插件',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          TextButton(onPressed: onOnline, child: Text(actionLabel)),
        ],
      ),
    );
  }
}

class _PluginCard extends StatelessWidget {
  const _PluginCard({
    required this.plugin,
    required this.dragIndex,
    required this.busy,
    required this.selectable,
    required this.selected,
    required this.isPlaying,
    required this.onSelect,
    required this.onToggle,
    required this.onInfo,
    required this.onUserVariables,
    required this.onUpdate,
    required this.onRemove,
  });

  final _PluginInfo plugin;

  /// 拖拽手柄对应的列表下标；小于 0（批量选择模式）时不显示手柄。
  final int dragIndex;
  final bool busy;
  final bool selectable;
  final bool selected;

  /// 当前播放歌曲正由该插件解析（播放解析指示）。
  final bool isPlaying;
  final ValueChanged<bool> onSelect;
  final ValueChanged<bool> onToggle;
  final VoidCallback onInfo;
  final VoidCallback? onUserVariables;
  final VoidCallback? onUpdate;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.fromLTRB(7, 12, 7, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(XyRadii.large),
        border: Border.all(
          color: dark ? XyColors.darkBorder : XyColors.lightBorder,
        ),
      ),
      child: Row(
        children: [
          if (selectable)
            Checkbox(
              value: selected,
              onChanged: busy ? null : (value) => onSelect(value ?? false),
            )
          else if (dragIndex >= 0)
            // 只有拖拽手柄区域可以发起排序拖拽，卡片其它位置不响应。
            ReorderableDragStartListener(
              index: dragIndex,
              child: SizedBox(
                width: 36,
                height: 46,
                child: Icon(
                  Icons.drag_indicator_rounded,
                  size: 22,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        plugin.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    if (plugin.isStarSea) ...[
                      const SizedBox(width: 6),
                      _StarSeaBadge(),
                    ],
                    if (plugin.sourceLabel?.trim().isNotEmpty == true) ...[
                      const SizedBox(width: 6),
                      _PluginSourceBadge(label: plugin.sourceLabel!.trim()),
                    ],
                    if (isPlaying) ...[
                      const SizedBox(width: 6),
                      const _PlayingBadge(),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  [
                    'v${plugin.version}',
                    if (plugin.author?.isNotEmpty == true) plugin.author!,
                    plugin.isOnline ? '在线' : '本地',
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          // 在线插件在卡片上直接暴露更新入口（三点菜单里也有同项），
          // 订阅插件频繁迭代，藏太深用户找不到更新导致旧版本越用越旧。
          if (onUpdate != null)
            IconButton(
              visualDensity: VisualDensity.compact,
              iconSize: 20,
              tooltip: '检查并安装更新',
              onPressed: busy ? null : onUpdate,
              icon: const Icon(Icons.refresh_rounded),
            ),
          Switch(value: plugin.enabled, onChanged: busy ? null : onToggle),
          PopupMenuButton<String>(
            enabled: !busy,
            onSelected: (value) {
              if (value == 'info') onInfo();
              if (value == 'variables') onUserVariables?.call();
              if (value == 'update') onUpdate?.call();
              if (value == 'remove') onRemove();
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'info', child: Text('插件信息')),
              if (onUserVariables != null)
                const PopupMenuItem(value: 'variables', child: Text('用户变量')),
              if (onUpdate != null)
                const PopupMenuItem(value: 'update', child: Text('检查并安装更新')),
              const PopupMenuItem(value: 'remove', child: Text('卸载插件')),
            ],
          ),
        ],
      ),
    );
  }
}

class _StarSeaBadge extends StatelessWidget {
  const _StarSeaBadge();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        '星海',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
          height: 1.1,
        ),
      ),
    );
  }
}

/// 音源来源徽标（IKUN / 聆澜…）。
///
/// 多租户订阅源里同一插件（如「QQ音乐」）按 `?source=` 有多个授权版本，
/// 它们名称完全相同、靠 ID 后缀区分才能并存。ID 不适合展示，故在名称旁
/// 挂一个来源小标签，让用户在列表里一眼分辨这条音源来自哪个渠道。
class _PluginSourceBadge extends StatelessWidget {
  const _PluginSourceBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.tertiary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
          height: 1.1,
        ),
      ),
    );
  }
}

/// 当前播放歌曲正由该插件解析的指示徽章。
class _PlayingBadge extends StatelessWidget {
  const _PlayingBadge();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.tertiary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.graphic_eq_rounded, size: 10, color: color),
          const SizedBox(width: 3),
          Text(
            '播放中',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: color,
              height: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}

/// 插件管理页顶部横幅：说明插件把搜索范围扩展到全网音源。
class _PluginHeroBanner extends StatelessWidget {
  const _PluginHeroBanner();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(XyRadii.large),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            color.withValues(alpha: 0.14),
            color.withValues(alpha: 0.04),
          ],
        ),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.library_music_rounded, size: 24, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '你的音乐，更多来源',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 3),
                Text(
                  '安装普通插件或 LX 音源，聚合搜索、播放全网歌曲',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PluginInfoRow extends StatelessWidget {
  const _PluginInfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 3),
          Text(value),
        ],
      ),
    );
  }
}
