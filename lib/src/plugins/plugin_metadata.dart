import 'dart:convert';
import 'dart:math' as math;

/// 插件声明的用户变量（userVariables）。插件在脚本中声明变量键名、
/// 显示名和提示文案，由宿主提供编辑界面并把用户填写的值注入 env。
class PluginUserVariable {
  const PluginUserVariable({
    required this.key,
    this.name,
    this.hint,
  });

  final String key;
  final String? name;
  final String? hint;

  /// 展示名，缺省时回退为键名。
  String get displayName => name?.trim().isNotEmpty == true ? name!.trim() : key;
}

class PluginMetadata {
  const PluginMetadata({
    this.id,
    this.name,
    this.version,
    this.author,
    this.remark,
    this.userVariables = const [],
  });

  final String? id;
  final String? name;
  final String? version;
  final String? author;

  /// 插件备注/描述。不同插件可能使用 description、desc 或 remark。
  final String? remark;

  /// 插件声明的用户变量列表；未声明时为空。
  final List<PluginUserVariable> userVariables;

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
      remark: _clean(
        header['description'] ??
            header['desc'] ??
            header['remark'] ??
            exported['description'] ??
            exported['desc'] ??
            exported['remark'] ??
            json['description'] ??
            json['desc'] ??
            json['remark'],
      ),
      userVariables: _parseUserVariables(script, constants),
    );
  }

  /// 解析插件声明的 userVariables 数组：
  /// userVariables: [{ key: 'token', name: '令牌', hint: '提示' }, ...]
  /// 不执行插件脚本，用括号配对扫描提取数组文本后逐项解析字段。
  static List<PluginUserVariable> _parseUserVariables(
    String script,
    Map<String, String> constants,
  ) {
    final result = <PluginUserVariable>[];
    final seen = <String>{};
    final arrayPattern = RegExp(r'''userVariables\s*:\s*\[''');
    for (final match in arrayPattern.allMatches(script)) {
      final arrayText = _extractBalanced(script, match.end - 1, '[', ']');
      if (arrayText == null) continue;
      final objectPattern = RegExp(r'\{');
      for (final objectMatch in objectPattern.allMatches(arrayText)) {
        final objectText = _extractBalanced(
          arrayText,
          objectMatch.start,
          '{',
          '}',
        );
        if (objectText == null) continue;
        final key = _resolveExpression(
          _fieldValue(objectText, 'key') ?? '',
          constants,
        );
        if (key == null || key.trim().isEmpty || !seen.add(key.trim())) continue;
        result.add(
          PluginUserVariable(
            key: key.trim(),
            name: _resolveExpression(
              _fieldValue(objectText, 'name') ?? '',
              constants,
            ),
            hint: _resolveExpression(
              _fieldValue(objectText, 'hint') ?? '',
              constants,
            ),
          ),
        );
      }
      if (result.isNotEmpty) return result;
    }
    return result;
  }

  /// 提取 [start] 处开括号开始的配对文本（不含首尾括号）。字符串字面量
  /// 中的括号不计入深度。
  static String? _extractBalanced(
    String text,
    int start,
    String open,
    String close,
  ) {
    if (start < 0 || start >= text.length || text[start] != open) return null;
    var depth = 0;
    var inString = false;
    String? quote;
    for (var index = start; index < text.length; index++) {
      final char = text[index];
      if (inString) {
        if (char == r'\') {
          index++;
        } else if (quote != null && char == quote) {
          inString = false;
          quote = null;
        }
        continue;
      }
      if (char == '"' || char == "'") {
        inString = true;
        quote = char;
      } else if (char == open) {
        depth++;
      } else if (char == close) {
        depth--;
        if (depth == 0) return text.substring(start + 1, index);
      }
    }
    return null;
  }

  /// 提取对象文本中的顶层字段值表达式，如 `key: 'token'` 返回 `'token'`。
  static String? _fieldValue(String objectText, String field) {
    final match = RegExp(
      '''(?:^|[,\\{\\r\\n])\\s*["']?$field["']?\\s*:\\s*([^\\r\\n,}]+)''',
      caseSensitive: false,
    ).firstMatch(objectText);
    return match?.group(1)?.trim();
  }

  static Map<String, String> _parseHeader(String script) {
    // 元数据头只会出现在文件开头。限制范围可避免把函数文档里的 @name
    // 误识别为插件名称。
    final scope = script.substring(0, math.min(script.length, 64 * 1024));
    final result = <String, String>{};
    final pattern = RegExp(
      r'^\s*(?://+|/\*+|\*+)?\s*@(id|name|version|author|description|desc|remark)\s+(.+?)\s*(?:\*/)?\s*$',
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
    for (final key in const [
      'id',
      'platform',
      'name',
      'version',
      'author',
      'description',
      'desc',
      'remark',
    ]) {
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
        for (final key in const [
          'id',
          'platform',
          'name',
          'version',
          'author',
          'description',
          'desc',
          'remark',
        ])
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
