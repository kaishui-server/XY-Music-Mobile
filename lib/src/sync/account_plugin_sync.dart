import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/auth_provider.dart';
import '../core/db_path.dart';
import '../rust/api.dart';
import '../plugins/plugin_metadata.dart';
import '../plugins/plugin_runtime.dart';

/// 账号云同步的插件部分。
///
/// 插件脚本与电脑版使用同一份 `plugins.json` 数据格式，脚本内容使用
/// 反转 Base64 保存，避免上传时被网关误判为可执行脚本。下载时会自动
/// 写入移动端插件目录，并恢复云端的启用状态和来源地址。
class AccountPluginSync {
  // v2：旧版本会在上传失败时错误保存哈希，升级后必须强制重试一次。
  static const _lastHashPrefix = 'account_cloud_sync_plugins_hash_v2_';
  static const _enabledKey = 'mobileEnabledPlugins';
  static const _sourceUrlsKey = 'mobilePluginSourceUrlsV1';
  static const _maxPluginBytes = 5 * 1024 * 1024;

  static String _key(String accountId) => '$_lastHashPrefix${accountId.trim()}';

  static Future<PluginSyncResult> sync(
    AuthNotifier auth,
    ProviderContainer container,
  ) async {
    // 先下载再上传，避免新设备的空插件目录覆盖云端已有插件。
    final downloaded = await download(auth, container);
    final uploaded = await uploadIfChanged(auth, container);
    return PluginSyncResult(
      downloadedPlugins: downloaded.downloadedPlugins,
      uploadedPlugins: uploaded?.uploadedPlugins ?? 0,
      noChange: uploaded?.noChange ?? true,
      errors: [...downloaded.errors, ...?uploaded?.errors],
    );
  }

  static Future<PluginSyncResult?> uploadIfChanged(
    AuthNotifier auth,
    ProviderContainer container,
  ) async {
    final accountId = _accountId(auth);
    final plugins = await _readLocalPlugins(container);
    final hash = _hash(plugins);
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_key(accountId)) == hash) {
      return PluginSyncResult(noChange: true);
    }
    final result = await _upload(auth, accountId, plugins);
    // 只有全部插件都成功上传后才记录哈希；部分失败时保留重试机会，
    // 否则一次网络抖动会让后续自动同步永久跳过这批插件。
    if (result.errors.isEmpty) {
      await prefs.setString(_key(accountId), hash);
    }
    return result;
  }

  static Future<PluginSyncResult> upload(
    AuthNotifier auth,
    ProviderContainer container,
  ) async {
    final accountId = _accountId(auth);
    final plugins = await _readLocalPlugins(container);
    final result = await _upload(auth, accountId, plugins);
    final prefs = await SharedPreferences.getInstance();
    if (result.errors.isEmpty) {
      await prefs.setString(_key(accountId), _hash(plugins));
    }
    return result;
  }

  static Future<PluginSyncResult> _upload(
    AuthNotifier auth,
    String accountId,
    List<Map<String, dynamic>> plugins,
  ) async {
    final result = PluginSyncResult._();
    if (plugins.isEmpty) {
      // 服务端当前接口没有“清空插件快照”操作；空目录不上传，避免
      // 新设备登录时误清除云端数据。删除同步会在后续非空快照上传时
      // 由 is_first=true 重建快照。
      return result;
    }
    for (var index = 0; index < plugins.length; index++) {
      final plugin = plugins[index];
      try {
        await auth.requestBackendAction('plugin_sync_upload_one', {
          'user_id': accountId,
          'plugin': plugin,
          'is_first': index == 0,
        }, fetchTimeoutMs: 60000);
        result.uploadedPlugins++;
      } catch (error) {
        result.errors.add('${plugin['name'] ?? plugin['id']} 上传失败：$error');
      }
    }
    return result;
  }

  static Future<PluginSyncResult> download(
    AuthNotifier auth,
    ProviderContainer container,
  ) async {
    final result = PluginSyncResult._();
    final accountId = _accountId(auth);
    final data = await auth.requestBackendAction('plugin_sync_download', {
      'user_id': accountId,
    }, fetchTimeoutMs: 60000);
    final raw = data['plugins'];
    if (raw is! List || raw.isEmpty) return result;

    final dataDir = await container.read(appDataDirProvider.future);
    final pluginDir = Directory(p.join(dataDir, 'plugins'));
    if (!pluginDir.existsSync()) pluginDir.createSync(recursive: true);
    final prefs = await SharedPreferences.getInstance();
    final enabled = (prefs.getStringList(_enabledKey) ?? const <String>[])
        .toSet();
    final sourceUrls = _readSourceUrls(prefs);

    for (final value in raw.whereType<Map>()) {
      final item = Map<String, dynamic>.from(value);
      final encoded =
          item['scriptEncoded'] == true || item['script_encoded'] == true;
      final rawScript = item['script']?.toString() ?? '';
      if (rawScript.isEmpty) {
        result.errors.add('${item['name'] ?? item['id'] ?? '未知插件'}缺少脚本');
        continue;
      }
      try {
        final script = encoded ? _decodeScript(rawScript) : rawScript;
        _validateScript(script);
        final metadata = PluginMetadata.parse(script);
        final requestedId = item['id']?.toString().trim() ?? '';
        final id = _safePluginId(
          requestedId.isNotEmpty
              ? requestedId
              : metadata.id ?? metadata.name ?? 'plugin',
        );
        final file = File(p.join(pluginDir.path, '$id.js'));
        final incomingVersion =
            item['version']?.toString() ?? metadata.version ?? '0';
        if (file.existsSync()) {
          final localMeta = PluginMetadata.parse(await file.readAsString());
          if (_compareVersion(localMeta.version ?? '0', incomingVersion) >= 0) {
            // 同版本不覆盖本地脚本，但仍然恢复云端启用状态和来源地址。
            _restoreState(item, id, enabled, sourceUrls);
            continue;
          }
        }
        await savePluginScript(dataDir: dataDir, id: id, script: script);
        _restoreState(item, id, enabled, sourceUrls);
        result.downloadedPlugins++;
      } catch (error) {
        result.errors.add('${item['name'] ?? item['id'] ?? '未知插件'}恢复失败：$error');
      }
    }
    await prefs.setStringList(_enabledKey, enabled.toList());
    await prefs.setString(_sourceUrlsKey, jsonEncode(sourceUrls));
    container.invalidate(enabledMusicPluginsProvider);
    container.invalidate(pluginRuntimeProvider);
    return result;
  }

  static void _restoreState(
    Map<String, dynamic> item,
    String id,
    Set<String> enabled,
    Map<String, String> sourceUrls,
  ) {
    if (item['enabled'] == true) {
      enabled.add(id);
    } else if (item.containsKey('enabled')) {
      enabled.remove(id);
    }
    final source =
        (item['sourceUrl'] ?? item['source_url'] ?? item['url'])
            ?.toString()
            .trim() ??
        '';
    if (source.isNotEmpty) sourceUrls[id] = source;
  }

  static Future<List<Map<String, dynamic>>> _readLocalPlugins(
    ProviderContainer container,
  ) async {
    final dataDir = await container.read(appDataDirProvider.future);
    final directory = Directory(p.join(dataDir, 'plugins'));
    if (!directory.existsSync()) return const [];
    final prefs = await SharedPreferences.getInstance();
    final enabled = (prefs.getStringList(_enabledKey) ?? const <String>[])
        .toSet();
    final sourceUrls = _readSourceUrls(prefs);
    final result = <Map<String, dynamic>>[];
    for (final file in directory.listSync().whereType<File>()) {
      if (p.extension(file.path).toLowerCase() != '.js') continue;
      try {
        final script = await file.readAsString();
        if (utf8.encode(script).length > _maxPluginBytes) continue;
        final metadata = PluginMetadata.parse(script);
        final id = p.basenameWithoutExtension(file.path);
        final lower = script.toLowerCase();
        result.add({
          'id': id,
          'name': metadata.name ?? id,
          'format': _isLx(script) ? 'lx' : 'musicfree',
          'version': metadata.version ?? '0',
          'author': metadata.author ?? '',
          'description': '',
          'filePath': file.path,
          'importedAt': (await file.stat()).modified.millisecondsSinceEpoch,
          'enabled': enabled.contains(id),
          'sources': const <String>[],
          'sourceUrl': sourceUrls[id] ?? '',
          'script': _encodeScript(script),
          'scriptEncoded': true,
          if (lower.contains('lx.event')) 'isLx': true,
        });
      } catch (_) {
        // 单个损坏插件不应阻止其它插件同步。
      }
    }
    result.sort((a, b) => '${a['id']}'.compareTo('${b['id']}'));
    return result;
  }

  static Map<String, String> _readSourceUrls(SharedPreferences prefs) {
    try {
      final raw = prefs.getString(_sourceUrlsKey);
      if (raw == null) return <String, String>{};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, String>{};
      return decoded.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      );
    } catch (_) {
      return <String, String>{};
    }
  }

  static String _hash(List<Map<String, dynamic>> value) =>
      base64UrlEncode(utf8.encode(jsonEncode(value)));

  static String _encodeScript(String script) =>
      base64Encode(utf8.encode(script)).split('').reversed.join();

  static String _decodeScript(String value) =>
      utf8.decode(base64Decode(value.split('').reversed.join()));

  static void _validateScript(String script) {
    final trimmed = script.trim();
    if (trimmed.isEmpty) throw Exception('插件脚本为空');
    if (utf8.encode(script).length > _maxPluginBytes) {
      throw Exception('插件超过 5 MB 安全限制');
    }
    final lower = trimmed.toLowerCase();
    if (lower.startsWith('<html') || lower.startsWith('<!doctype html')) {
      throw Exception('云端返回的不是插件脚本');
    }
    if (!(lower.contains('@name') ||
        lower.contains('module.exports') ||
        lower.contains('export default') ||
        lower.contains('platform') ||
        lower.contains('lx.') ||
        lower.contains('musicfree'))) {
      throw Exception('无法识别插件格式');
    }
  }

  static String _safePluginId(String value) {
    final id = value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_-]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return id.isNotEmpty
        ? id
        : 'plugin-${DateTime.now().millisecondsSinceEpoch}';
  }

  static int _compareVersion(String left, String right) {
    final a = left.split(RegExp(r'[.-]'));
    final b = right.split(RegExp(r'[.-]'));
    final length = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < length; i++) {
      final av = i < a.length ? int.tryParse(a[i]) ?? 0 : 0;
      final bv = i < b.length ? int.tryParse(b[i]) ?? 0 : 0;
      if (av != bv) return av.compareTo(bv);
    }
    return 0;
  }

  static bool _isLx(String script) {
    final lower = script.toLowerCase();
    return lower.contains('lx.event') ||
        lower.contains('globalthis.lx') ||
        lower.contains('server_script_config');
  }

  static String _accountId(AuthNotifier auth) {
    final value = auth.currentUser?.xymusicId?.trim() ?? '';
    if (value.isEmpty) throw AuthException('请先登录账号');
    return value;
  }
}

class PluginSyncResult {
  PluginSyncResult({
    this.noChange = false,
    this.uploadedPlugins = 0,
    this.downloadedPlugins = 0,
    this.errors = const [],
  });

  PluginSyncResult._()
    : noChange = false,
      uploadedPlugins = 0,
      downloadedPlugins = 0,
      errors = <String>[];

  final bool noChange;
  int uploadedPlugins;
  int downloadedPlugins;
  final List<String> errors;
}
