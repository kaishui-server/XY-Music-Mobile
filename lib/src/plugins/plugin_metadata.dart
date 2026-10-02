import 'dart:convert';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

/// 插件声明的用户变量（userVariables）。插件在脚本中声明变量键名、
/// 显示名和提示文案，由宿主提供编辑界面并把用户填写的值注入 env。
class PluginUserVariable {
  const PluginUserVariable({required this.key, this.name, this.hint});

  final String key;
  final String? name;
  final String? hint;

  /// 展示名，缺省时回退为键名。
  String get displayName =>
      name?.trim().isNotEmpty == true ? name!.trim() : key;
}

class PluginMetadata {
  const PluginMetadata({
    this.id,
    this.name,
    this.version,
    this.author,
    this.remark,
    this.userVariables = const [],
    this.isStarSea = false,
    this.isLx = false,
    this.isBaka = false,
    this.isAnimemusic = false,
  });

  final String? id;
  final String? name;
  final String? version;
  final String? author;

  /// 插件备注/描述。不同插件可能使用 description、desc 或 remark。
  final String? remark;

  /// 插件声明的用户变量列表；未声明时为空。
  final List<PluginUserVariable> userVariables;

  /// 是否为星海格式插件：MusicFree 兼容的聚合变体（如惜梦
  /// animemusic 聚合 v4），歌曲带 _src/_source 来源标记，一次搜索
  /// 聚合多平台结果。
  final bool isStarSea;

  /// LX（洛雪）插件：走 globalThis.lx 契约而非 MusicFree
  /// module.exports。规则与 plugin_runtime 的 _looksLikeLxPlugin 一致。
  final bool isLx;

  /// BakaMusic 契约插件：getMvSource 方法或 animeSrc 歌曲来源标记
  /// 是该契约区别于 MusicFree/LX 的独有特征。
  final bool isBaka;

  /// animemusic 后端插件：直连 animemusic.bzxhkj.com（惜梦 v3/v4、
  /// animemusic/1 新格式等）。baka 版的 FALLBACK_BASE 也指向该域名，
  /// 分类时需先判 isBaka 再判本标记。
  final bool isAnimemusic;

  static PluginMetadata parse(String script) {
    final constants = _parseStringConstants(script);
    final header = _parseHeader(script);
    final exported = _parseExportedObject(script, constants);
    final json = _parseJsonObject(script);
    final constMeta = _parseConstMeta(script);

    return PluginMetadata(
      id: _clean(header['id'] ?? exported['id'] ?? json['id']),
      // MusicFree 使用 platform 作为插件显示名；LX 常用 @name。
      name: _clean(
        header['name'] ??
            exported['platform'] ??
            exported['name'] ??
            json['platform'] ??
            json['name'] ??
            constMeta['name'],
      ),
      version: _clean(
        header['version'] ??
            exported['version'] ??
            json['version'] ??
            constMeta['version'],
      ),
      author: _clean(
        header['author'] ??
            exported['author'] ??
            json['author'] ??
            constMeta['author'],
      ),
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
      isStarSea: _detectStarSea(script),
      isLx: _detectLx(script),
      isBaka: _detectBaka(script),
      isAnimemusic: _detectAnimemusic(script),
    );
  }

  /// 插件 ID 归一化：转小写，把字母数字/中文/下划线/连字符以外的字符
  /// 折叠为 '-'，再剥掉首尾 '-'。保留中文字符——剥离中文会让
  /// 「animemusic聚合」与「animemusic」折叠成同一个 ID，批量安装时
  /// 互相覆盖（提示装了 6 个、列表只剩 3 个）。归一化结果为空时由
  /// 调用方回退到内容哈希。
  static String normalizePluginId(String rawId) {
    return rawId
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_\-\u3400-\u4dbf\u4e00-\u9fff]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
  }

  /// 由脚本内容与安装来源推断插件 ID（安装、更新、备份恢复、去重
  /// 共用同一套规则，避免同一插件在不同入口算出不同 ID）：
  /// metadata.id → metadata.name（MusicFree 的 platform）→ 来源 URL
  /// 文件名，归一化后作为稳定 ID；归一化为空（纯符号名）时回退到
  /// 内容哈希 plugin-xxxxxxxx。订阅插件更新后 name 变化（如加上了
  /// 「(赞助版)[永久]」后缀）会导致 ID 漂移，调用方需迁移旧 ID 引用
  /// （见 plugin_reference_migration.dart）。
  static String resolvePluginId(String script, String origin) =>
      resolvePluginIdFromMetadata(parse(script), origin);

  /// 与 [resolvePluginId] 同规则，但复用已解析好的元数据，避免批量安装时
  /// 对同一段脚本重复执行整套正则解析（脚本可达数百 KB，重复解析是批量
  /// 导入卡顿的主要来源）。
  static String resolvePluginIdFromMetadata(
    PluginMetadata metadata,
    String origin,
  ) {
    // file_picker/下载管理器给的来源路径常带中文，Uri.path 会以百分号
    // 编码返回（QQ音乐 → %E9%9F%B3%E4%B9%90），不解码会让回退 ID 变成
    // qq-e9-9f-b3 这类 UTF-8 字节十六进制串。
    final uri = Uri.tryParse(origin);
    final uriPath = uri == null ? '' : _decodeUriPath(uri.path);
    final rawName =
        metadata.name ??
        p.basenameWithoutExtension(uriPath.isNotEmpty ? uriPath : origin);
    final rawId = metadata.id ?? rawName;
    final normalized = normalizePluginId(rawId);
    return normalized.isNotEmpty
        ? normalized
        : 'plugin-${_fnv1a(rawId).toRadixString(16)}';
  }

  /// 插件版本号比较（按 `.` `-` 分段做数字比较，段缺失按 0）。
  /// 返回正数表示 [left] 更新、0 表示相同、负数表示更旧。
  static int compareVersions(String left, String right) {
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

  static String _decodeUriPath(String path) {
    if (!path.contains('%')) return path;
    try {
      return Uri.decodeComponent(path);
    } on ArgumentError {
      return path;
    }
  }

  /// FNV-1a 32 位哈希，用于无法归一化的插件名生成回退 ID。
  static int _fnv1a(String input) {
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(input)) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash;
  }

  /// LX（洛雪）插件静态识别（不执行脚本），与 plugin_runtime 的
  /// _looksLikeLxPlugin 规则保持一致；压缩/混淆后的脚本可能写成
  /// globalThis['lx']，不能只认点号形式。
  static bool _detectLx(String script) {
    final lower = script.toLowerCase();
    return lower.contains('lx.event.request') ||
        lower.contains('lx.event.on') ||
        lower.contains('globalthis.lx') ||
        RegExp(r'''globalthis\s*\[\s*['"]lx['"]\s*\]''').hasMatch(lower) ||
        lower.contains('event_names.request') ||
        lower.contains('server_script_config');
  }

  /// BakaMusic 契约静态识别：getMvSource 方法（MusicFree 的 MV 方法
  /// 叫 getMV、LX 走事件契约）与 animeSrc 歌曲来源标记是该契约独有。
  static bool _detectBaka(String script) {
    final lower = script.toLowerCase();
    return lower.contains('getmvsource') || lower.contains('animesrc');
  }

  /// animemusic（惜梦动画音乐）插件识别：
  /// - 老站点域名 `animemusic.bzxhkj.com`；
  /// - 新插件（如 qishui，API 域名为 `anime.bzxhkj.com`）不再包含老域名，
  ///   但在 META 中声明 `format: "animemusic/1"` 规范，与运行时
  ///   `_looksLikeAnimemusicPlugin` 的判定对齐，避免被误分类到
  ///   MusicFree 插件页。
  /// baka 版兜底地址也指向老域名，分类时先判 isBaka；v2 洛雪版同样
  /// 命中，但分类时 isLx 优先级更高。
  static bool _detectAnimemusic(String script) {
    if (script.contains('animemusic.bzxhkj.com')) return true;
    return RegExp(
          r'''["']format["']\s*:\s*["']animemusic/1["']''',
        ).hasMatch(script) ||
        (RegExp(r'''module\.exports\s*=\s*\w+''').hasMatch(script) &&
            script.contains('animemusic/1'));
  }

  /// 星海格式静态识别（不执行脚本）：
  /// - primaryKey 含 "_src"：聚合多平台时不同平台 id 会撞车，星海规范
  ///   要求把来源键纳入主键（如 primaryKey: ["id", "_src"]）；
  /// - 插件读取歌曲的 `._src` / `._source` 来源标记：星海歌曲字段约定，
  ///   MusicFree/LX 规范均无此字段。
  static bool _detectStarSea(String script) {
    if (RegExp(r'''primaryKey\s*:\s*\[[^\]]*_src''').hasMatch(script)) {
      return true;
    }
    return RegExp(r'''\.\s*_src\b|\.\s*_source\b''').hasMatch(script);
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
        if (key == null || key.trim().isEmpty || !seen.add(key.trim())) {
          continue;
        }
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

  /// animemusic/1 等新格式插件把元信息放在 `const META = { ... }` 单行
  /// JSON 常量里，且 module.exports 导出的是变量而非对象字面量，前面
  /// 的静态解析都取不到名称；这里单独截取该常量做一次 JSON 解析兜底。
  static Map<String, String> _parseConstMeta(String script) {
    final match = RegExp(
      r'const\s+META\s*=\s*(\{[^\n;]+\})\s*;',
    ).firstMatch(script);
    if (match == null) return const {};
    try {
      final value = jsonDecode(match.group(1)!);
      if (value is! Map) return const {};
      return {
        for (final key in const ['id', 'name', 'version', 'author', 'platform'])
          if (value[key] != null && value[key].toString().trim().isNotEmpty)
            key: value[key].toString(),
      };
    } catch (_) {
      return const {};
    }
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
    if (lastMatch != null) {
      final result = _parseExportFields(
        _extractExportObjectBody(script, lastMatch.end),
        constants,
      );
      if (result.isNotEmpty) return result;
    }
    return _parseVariableExport(script, constants);
  }

  /// `module.exports = MF_PLUGIN;`（导出的是变量而非对象字面量，
  /// 插件改造器生成的插件常见）：定位该标识符的 const/let/var 对象
  /// 字面量声明，再从声明的对象体中解析元数据字段。
  static Map<String, String> _parseVariableExport(
    String script,
    Map<String, String> constants,
  ) {
    final variablePatterns = [
      RegExp(r'module\.exports\s*=\s*([A-Za-z_$][\w$]*)\s*;'),
      RegExp(r'exports\.default\s*=\s*([A-Za-z_$][\w$]*)\s*;'),
      RegExp(r'export\s+default\s+([A-Za-z_$][\w$]*)\s*;'),
    ];
    for (final pattern in variablePatterns) {
      for (final match in pattern.allMatches(script)) {
        final identifier = match.group(1)!;
        final declaration = RegExp(
          '(?:const|let|var)\\s+${RegExp.escape(identifier)}\\s*=\\s*\\{',
        ).firstMatch(script);
        if (declaration == null) continue;
        final result = _parseExportFields(
          _extractExportObjectBody(script, declaration.end),
          constants,
        );
        if (result.isNotEmpty) return result;
      }
    }
    return const {};
  }

  /// 提取导出对象字面量的正文（`{` 之后到配对 `}` 之前）：跳过字符串、
  /// 模板字符串与注释中的花括号。不按配对括号截断时，对象之后的代码
  /// （如插件内置的示例歌曲 `id: 'qq_xxx'`）会污染 id/name 字段。
  static String _extractExportObjectBody(String script, int bodyStart) {
    final n = script.length;
    var depth = 1;
    var i = bodyStart;
    while (i < n && depth > 0) {
      final ch = script.codeUnitAt(i);
      if (ch == 0x27 || ch == 0x22 || ch == 0x60) {
        final quote = ch;
        i++;
        while (i < n) {
          final c = script.codeUnitAt(i);
          if (c == 0x5C) {
            i += 2;
            continue;
          }
          if (c == quote) {
            i++;
            break;
          }
          i++;
        }
        continue;
      }
      if (ch == 0x2F &&
          i + 1 < n &&
          (script.codeUnitAt(i + 1) == 0x2F ||
              script.codeUnitAt(i + 1) == 0x2A)) {
        final block = script.codeUnitAt(i + 1) == 0x2A;
        i += 2;
        if (block) {
          while (i + 1 < n &&
              !(script.codeUnitAt(i) == 0x2A &&
                  script.codeUnitAt(i + 1) == 0x2F)) {
            i++;
          }
          i += 2;
        } else {
          while (i < n && script.codeUnitAt(i) != 0x0A) {
            i++;
          }
        }
        continue;
      }
      if (ch == 0x7B) depth++;
      if (ch == 0x7D) depth--;
      i++;
    }
    final end = depth == 0 ? i - 1 : i;
    return script.substring(
      bodyStart,
      math.min(end, math.min(n, bodyStart + 16 * 1024)),
    );
  }

  static Map<String, String> _parseExportFields(
    String scope,
    Map<String, String> constants,
  ) {
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
      ).firstMatch(_maskNestedScope(scope));
      if (field == null) continue;
      final value = _resolveExpression(field.group(1)!, constants);
      if (value != null && value.isNotEmpty) result[key] = value;
    }
    return result;
  }

  /// 把导出对象正文中嵌套层级（方法体、数组、内层对象）的内容替换为
  /// 空白，只保留顶层字段供提取：插件方法体内的示例数据（如 debug
  /// 方法的 fakeItem）带 id/name 字段，不屏蔽会污染插件元数据。
  static String _maskNestedScope(String scope) {
    final n = scope.length;
    final buffer = StringBuffer();
    var depth = 0;
    var i = 0;
    while (i < n) {
      final ch = scope.codeUnitAt(i);
      if (ch == 0x27 || ch == 0x22 || ch == 0x60) {
        final quote = ch;
        var j = i + 1;
        while (j < n) {
          final c = scope.codeUnitAt(j);
          if (c == 0x5C) {
            j += 2;
            continue;
          }
          if (c == quote) {
            j++;
            break;
          }
          j++;
        }
        if (depth == 0) {
          buffer.write(scope.substring(i, j));
        } else {
          buffer.write(' ' * (j - i));
        }
        i = j;
        continue;
      }
      if (ch == 0x2F && i + 1 < n) {
        final next = scope.codeUnitAt(i + 1);
        if (next == 0x2F || next == 0x2A) {
          var j = i + 2;
          if (next == 0x2A) {
            while (j + 1 < n &&
                !(scope.codeUnitAt(j) == 0x2A &&
                    scope.codeUnitAt(j + 1) == 0x2F)) {
              j++;
            }
            j += 2;
          } else {
            while (j < n && scope.codeUnitAt(j) != 0x0A) {
              j++;
            }
          }
          buffer.write(' ' * (j - i));
          i = j;
          continue;
        }
      }
      if (ch == 0x7B || ch == 0x5B) {
        depth++;
        buffer.write(' ');
        i++;
        continue;
      }
      if (ch == 0x7D || ch == 0x5D) {
        if (depth > 0) depth--;
        buffer.write(' ');
        i++;
        continue;
      }
      buffer.writeCharCode(depth == 0 ? ch : 0x20);
      i++;
    }
    return buffer.toString();
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
