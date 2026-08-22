import 'dart:convert';
import 'dart:math' as math;

class PluginMetadata {
  const PluginMetadata({this.id, this.name, this.version, this.author});

  final String? id;
  final String? name;
  final String? version;
  final String? author;

  static PluginMetadata parse(String script) {
    final constants = _parseStringConstants(script);
    final header = _parseHeader(script);
    final exported = _parseExportedObject(script, constants);
    final json = _parseJsonObject(script);

    return PluginMetadata(
      id: _clean(header['id'] ?? exported['id'] ?? json['id']),
      // MusicFree 使用 platform 作为插件显示名；LX 常用 @name。
      name: _clean(
        header['name'] ??
            exported['platform'] ??
            exported['name'] ??
            json['platform'] ??
            json['name'],
      ),
      version: _clean(
        header['version'] ?? exported['version'] ?? json['version'],
      ),
      author: _clean(header['author'] ?? exported['author'] ?? json['author']),
    );
  }

  static Map<String, String> _parseHeader(String script) {
    // 元数据头只会出现在文件开头。限制范围可避免把函数文档里的 @name
    // 误识别为插件名称。
    final scope = script.substring(0, math.min(script.length, 64 * 1024));
    final result = <String, String>{};
    final pattern = RegExp(
      r'^\s*(?://+|/\*+|\*+)?\s*@(id|name|version|author)\s+(.+?)\s*(?:\*/)?\s*$',
      caseSensitive: false,
      multiLine: true,
    );
    for (final match in pattern.allMatches(scope)) {
      final key = match.group(1)!.toLowerCase();
      final value = match.group(2)!.trim();
      result.putIfAbsent(key, () => value);
    }
    return result;
  }

  static Map<String, String> _parseStringConstants(String script) {
    final result = <String, String>{};
    final scope = script.substring(0, math.min(script.length, 128 * 1024));
    final patterns = [
      RegExp(
        r'''(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*"([^"\r\n]*)"\s*;''',
      ),
      RegExp(r"(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*'([^'\r\n]*)'\s*;"),
    ];
    for (final pattern in patterns) {
      for (final match in pattern.allMatches(scope)) {
        result[match.group(1)!] = match.group(2)!;
      }
    }
    return result;
  }

  static Map<String, String> _parseExportedObject(
    String script,
    Map<String, String> constants,
  ) {
    final exportPatterns = [
      RegExp(r'module\.exports\s*=\s*\{'),
      RegExp(r'exports\.default\s*=\s*\{'),
      RegExp(r'export\s+default\s*\{'),
    ];
    RegExpMatch? lastMatch;
    for (final pattern in exportPatterns) {
      for (final match in pattern.allMatches(script)) {
        if (lastMatch == null || match.start > lastMatch.start) {
          lastMatch = match;
        }
      }
    }
    if (lastMatch == null) return const {};

    final end = math.min(script.length, lastMatch.end + 16 * 1024);
    final scope = script.substring(lastMatch.end, end);
    final result = <String, String>{};
    for (final key in const ['id', 'platform', 'name', 'version', 'author']) {
      final field = RegExp(
        '(?:^|[,\\r\\n])\\s*["\\\']?$key["\\\']?\\s*:\\s*([^\\r\\n,}]+)',
        caseSensitive: false,
        multiLine: true,
      ).firstMatch(scope);
      if (field == null) continue;
      final value = _resolveExpression(field.group(1)!, constants);
      if (value != null && value.isNotEmpty) result[key] = value;
    }
    return result;
  }

  static String? _resolveExpression(
    String expression,
    Map<String, String> constants,
  ) {
    final quoted = RegExp(r'''["']([^"']*)["']''').firstMatch(expression);
    String? result = quoted?.group(1);

    // version: VERSION / platform: "网易云音乐" + (IS_PAID ? IS_PAID : "")
    // 均可通过顶层字符串常量静态还原，无需执行不受信任的插件脚本。
    for (final entry in constants.entries) {
      if (!RegExp('\\b${RegExp.escape(entry.key)}\\b').hasMatch(expression)) {
        continue;
      }
      if (result == null || result.isEmpty) {
        result = entry.value;
      } else if (entry.value.isNotEmpty && !result.contains(entry.value)) {
        result += entry.value;
      }
    }
    return result;
  }

  static Map<String, String> _parseJsonObject(String script) {
    final trimmed = script.trim();
    if (!trimmed.startsWith('{')) return const {};
    try {
      final value = jsonDecode(trimmed);
      if (value is! Map) return const {};
      final map = Map<String, dynamic>.from(value);
      return {
        for (final key in const ['id', 'platform', 'name', 'version', 'author'])
          if (map[key] != null) key: map[key].toString(),
      };
    } catch (_) {
      return const {};
    }
  }

  static String? _clean(String? value) {
    final cleaned = value?.replaceFirst(RegExp(r'\s*\*/\s*$'), '').trim();
    return cleaned == null || cleaned.isEmpty ? null : cleaned;
  }
}
