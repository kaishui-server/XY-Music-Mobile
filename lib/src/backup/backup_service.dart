import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/custom_font.dart';
import '../core/db_path.dart';
import '../rust/api.dart' as rust;

/// 备份/恢复失败时抛出的异常，[message] 直接展示给用户。
class BackupException implements Exception {
  const BackupException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 外观自定义文件条目：[name] 为 appearance 目录内的文件名，
/// [base64] 为文件内容（导入时写回 appearance 目录）。
class BackupAppearanceFile {
  const BackupAppearanceFile({required this.name, required this.base64});

  final String name;
  final String base64;

  Map<String, Object> toJson() => {'name': name, 'base64': base64};
}

/// 备份中的外观自定义文件（v3 起）：全局壁纸、播放详情页背景、
/// 自定义字体。任一项缺失时对应字段为 null。
class BackupAppearance {
  const BackupAppearance({this.background, this.playerDetail, this.font});

  final BackupAppearanceFile? background;
  final BackupAppearanceFile? playerDetail;
  final BackupAppearanceFile? font;

  bool get isEmpty =>
      background == null && playerDetail == null && font == null;

  Map<String, Object> toJson() {
    final map = <String, Object>{};
    final bg = background;
    if (bg != null) map['background'] = bg.toJson();
    final detail = playerDetail;
    if (detail != null) map['playerDetail'] = detail.toJson();
    final customFont = font;
    if (customFont != null) map['font'] = customFont.toJson();
    return map;
  }
}

/// 解析并校验通过的一份备份数据（尚未写入本地）。
class BackupData {
  const BackupData({
    required this.exportedAt,
    required this.prefs,
    required this.plugins,
    this.library = const {},
    this.appearance = const BackupAppearance(),
  });

  /// 导出时间（ISO 8601 字符串，可能为空——仅用于展示）。
  final String exportedAt;

  /// {key: {'t': 's|b|i|d|sl', 'v': ...}}，全部条目均已校验合法。
  final Map<String, Map<String, Object>> prefs;

  /// {插件 id: js 脚本全文}。
  final Map<String, String> plugins;

  /// 曲库表数据（Rust 导出的 {"表名": {columns, rows}} 结构；v1 备份为空）。
  final Map<String, dynamic> library;

  /// 外观自定义文件（v3 起）；v1/v2 备份为空。
  final BackupAppearance appearance;

  int get prefCount => prefs.length;

  int get pluginCount => plugins.length;

  /// 备份中的本地曲库歌曲数（songs 表行数，仅用于展示）。
  int get librarySongCount {
    final songs = library['songs'];
    if (songs is! Map) return 0;
    final rows = songs['rows'];
    return rows is List ? rows.length : 0;
  }
}

/// 导入完成后的统计。
class BackupImportResult {
  const BackupImportResult({required this.prefCount, required this.pluginCount});

  final int prefCount;
  final int pluginCount;
}

/// 本地备份：把歌单、收藏、插件（含用户变量）、主题与全部设置
/// （全部 SharedPreferences 数据 + plugins 目录脚本）导出为单个 JSON
/// 文件，导入时整体写回。设置项 key 无统一前缀且会持续新增，因此
/// 采用全量导出（黑名单排除设备标识），保证未来新增设置自动被备份。
class BackupService {
  const BackupService();

  static const formatId = 'xymusic-backup';
  // v2：新增内嵌本地曲库表（songs/library_folders/artists 等），本地收藏与
  // 歌单歌曲依赖这些缓存才能恢复显示。读取时兼容 v1（无曲库字段）。
  // v3：新增外观自定义文件（全局壁纸、播放详情页背景、自定义字体），
  // 导入时写回 appearance 目录并修正设置中的绝对路径。读取时兼容 v1/v2。
  static const int version = 3;

  /// 不随备份迁移的键：deviceId 是本机设备标识，不应在新设备复用。
  static const _excludedKeys = <String>{'deviceId'};

  /// 外观文件大小上限（与设置页选择文件时的限制一致）：
  /// 图片 20MB、字体 100MB，超限的文件不进备份。
  static const int _maxImageBytes = 20 * 1024 * 1024;
  static const int _maxFontBytes = 100 * 1024 * 1024;

  /// 导出全部本地数据，弹系统保存对话框由用户选择保存位置。
  /// 返回保存路径；用户取消时返回 null。
  Future<String?> exportBackup() async {
    final prefs = await SharedPreferences.getInstance();
    final prefsDump = <String, Map<String, Object>>{};
    for (final key in prefs.getKeys()) {
      if (_excludedKeys.contains(key)) continue;
      final entry = _encodeValue(prefs.get(key));
      if (entry != null) prefsDump[key] = entry;
    }
    final plugins = await _readPluginSources();
    final library = await _exportLibrary();
    final appearance = await _exportAppearance(prefs);
    final payload = <String, Object>{
      'format': formatId,
      'version': version,
      'exportedAt': DateTime.now().toIso8601String(),
      'prefs': prefsDump,
      'plugins': plugins,
      'library': library,
      if (!appearance.isEmpty) 'appearance': appearance.toJson(),
    };
    final text = const JsonEncoder.withIndent('  ').convert(payload);
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final fileName =
        'xy_music_backup_${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}.json';
    final path = await FilePicker.platform.saveFile(
      dialogTitle: '导出备份',
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: const ['json'],
      bytes: utf8.encode(text),
    );
    return (path == null || path.isEmpty) ? null : path;
  }

  /// 读取并校验备份文件（不写入任何数据）。
  /// 文件损坏、格式或版本不识别时抛 [BackupException]。
  Future<BackupData> readBackup(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw const BackupException('备份文件不存在');
    }
    final Object decoded;
    try {
      decoded = jsonDecode(await file.readAsString());
    } on FormatException {
      throw const BackupException('文件损坏或不是有效的备份文件');
    } on FileSystemException {
      throw const BackupException('备份文件读取失败');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const BackupException('文件损坏或不是有效的备份文件');
    }
    if (decoded['format'] != formatId) {
      throw const BackupException('这不是 XY Music 的备份文件');
    }
    final fileVersion = decoded['version'];
    if (fileVersion is! int || fileVersion < 1) {
      throw const BackupException('备份文件版本无法识别');
    }
    if (fileVersion > version) {
      throw const BackupException('备份来自更新版本的应用，请先升级后再导入');
    }

    // prefs：整体校验通过后才返回，调用方确认后才写入。
    final rawPrefs = decoded['prefs'];
    if (rawPrefs is! Map) {
      throw const BackupException('备份文件缺少设置数据');
    }
    final prefs = <String, Map<String, Object>>{};
    for (final entry in rawPrefs.entries) {
      final key = entry.key.toString();
      final value = entry.value;
      if (value is! Map) continue;
      final t = value['t'];
      final v = value['v'];
      if (t is! String) continue;
      if (!_valueMatchesType(v, t)) continue;
      prefs[key] = {'t': t, 'v': v as Object};
    }

    // plugins：插件 id 必须是安全文件名，防止路径穿越。
    final rawPlugins = decoded['plugins'];
    final plugins = <String, String>{};
    if (rawPlugins is Map) {
      for (final entry in rawPlugins.entries) {
        final id = entry.key.toString();
        final source = entry.value;
        if (source is! String || source.isEmpty) continue;
        if (!_isSafePluginId(id)) continue;
        plugins[id] = source;
      }
    }

    // library：v2 起内嵌的曲库表数据（v1 备份没有该字段，跳过曲库恢复）。
    final library = <String, dynamic>{};
    final rawLibrary = decoded['library'];
    if (rawLibrary is Map) {
      for (final entry in rawLibrary.entries) {
        if (entry.value is Map) library[entry.key.toString()] = entry.value;
      }
    }

    // appearance：v3 起内嵌的外观自定义文件（v1/v2 备份没有该字段）。
    // 文件名不安全、base64 损坏或超限的条目在解析时直接跳过。
    final rawAppearance = decoded['appearance'];
    var appearance = const BackupAppearance();
    if (rawAppearance is Map) {
      appearance = BackupAppearance(
        background: _decodeAppearanceEntry(
          rawAppearance['background'],
          maxBytes: _maxImageBytes,
        ),
        playerDetail: _decodeAppearanceEntry(
          rawAppearance['playerDetail'],
          maxBytes: _maxImageBytes,
        ),
        font: _decodeAppearanceEntry(
          rawAppearance['font'],
          maxBytes: _maxFontBytes,
        ),
      );
    }
    return BackupData(
      exportedAt: decoded['exportedAt']?.toString() ?? '',
      prefs: prefs,
      plugins: plugins,
      library: library,
      appearance: appearance,
    );
  }

  /// 把校验通过的备份写入本地：先整体恢复曲库表（SQLite 事务，失败即中止），
  /// 再逐条写回 SharedPreferences，最后把插件脚本写入 plugins 目录（同名
  /// 覆盖——恢复语义）。调用前应已通过 [readBackup] 校验并经用户确认。
  Future<BackupImportResult> applyBackup(BackupData data) async {
    final dbPath = p.join(await resolveAppDataDir(), 'library.db');
    if (data.library.isNotEmpty) {
      try {
        await rust.importLibraryTables(
          dbPath: dbPath,
          payload: jsonEncode(data.library),
        );
      } catch (e) {
        throw BackupException('曲库恢复失败：$e');
      }
    }
    final prefs = await SharedPreferences.getInstance();
    for (final entry in data.prefs.entries) {
      final t = entry.value['t']!;
      final v = entry.value['v']!;
      switch (t) {
        case 's':
          await prefs.setString(entry.key, v as String);
        case 'b':
          await prefs.setBool(entry.key, v as bool);
        case 'i':
          await prefs.setInt(entry.key, v is int ? v : (v as num).toInt());
        case 'd':
          await prefs.setDouble(
            entry.key,
            v is double ? v : (v as num).toDouble(),
          );
        case 'sl':
          await prefs.setStringList(entry.key, (v as List).cast<String>());
      }
    }
    final pluginCount = data.plugins.length;
    if (data.plugins.isNotEmpty) {
      final dir = Directory(
        p.join(await resolveAppDataDir(), 'plugins'),
      );
      if (!dir.existsSync()) dir.createSync(recursive: true);
      for (final entry in data.plugins.entries) {
        await File(p.join(dir.path, '${entry.key}.js')).writeAsString(
          entry.value,
        );
      }
    }

    // 外观自定义文件（v3 起）：写回 appearance 目录，并把 prefs 里的
    // 图片路径改写为本机路径（备份里的路径指向导出设备，在本机无效）。
    if (!data.appearance.isEmpty) {
      final dir = Directory(
        p.join(await resolveAppDataDir(), 'appearance'),
      );
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final imageEntries = <String, BackupAppearanceFile?>{
        'customBackgroundPath': data.appearance.background,
        'playerDetailCustomImagePath': data.appearance.playerDetail,
      };
      for (final entry in imageEntries.entries) {
        final file = entry.value;
        if (file == null) continue;
        try {
          final target = p.join(dir.path, file.name);
          await File(target).writeAsBytes(base64Decode(file.base64));
          await prefs.setString(entry.key, target);
        } on FormatException {
          // 读取时已校验过 base64，正常不会到这里；防御性跳过。
        } on FileSystemException {
          // 单个文件写回失败时跳过，不影响其余数据恢复。
        }
      }
      final font = data.appearance.font;
      if (font != null) {
        try {
          // 字体固定写 custom_font.ttf（与 customFontFilePath 一致），
          // fontFamily 设置已随 prefs 恢复，无需改写路径。
          await File(await customFontFilePath()).writeAsBytes(
            base64Decode(font.base64),
          );
        } on FileSystemException {
          // 写回失败时字体回退系统默认，不影响其余数据。
        }
      }
    }
    return BackupImportResult(
      prefCount: data.prefCount,
      pluginCount: pluginCount,
    );
  }

  /// 按运行时类型把 SharedPreferences 的值编码成 {t, v} 条目；
  /// 不认识的类型返回 null（跳过，不进备份）。
  Map<String, Object>? _encodeValue(Object? value) {
    if (value is String) return {'t': 's', 'v': value};
    if (value is bool) return {'t': 'b', 'v': value};
    if (value is int) return {'t': 'i', 'v': value};
    if (value is double) return {'t': 'd', 'v': value};
    if (value is List && value.every((e) => e is String)) {
      return {'t': 'sl', 'v': value};
    }
    return null;
  }

  /// 校验解码后的值与类型标记匹配。
  bool _valueMatchesType(Object? v, String t) {
    switch (t) {
      case 's':
        return v is String;
      case 'b':
        return v is bool;
      case 'i':
        return v is int;
      case 'd':
        return v is num;
      case 'sl':
        return v is List && v.every((e) => e is String);
      default:
        return false;
    }
  }

  /// 插件 id 只允许字母/数字/下划线/连字符，杜绝目录分隔符与 ".."
  /// 穿越。
  bool _isSafePluginId(String id) =>
      RegExp(r'^[A-Za-z0-9_\-]+$').hasMatch(id);

  /// 外观文件名只允许字母/数字/下划线/连字符/点，且不能以点开头或
  /// 包含 ".."，杜绝路径分隔符与目录穿越。
  bool _isSafeAppearanceFileName(String name) =>
      RegExp(r'^[A-Za-z0-9_\-][A-Za-z0-9_\-.]*$').hasMatch(name) &&
      !name.contains('..');

  /// 导出外观自定义文件：全局壁纸、播放详情页背景与自定义字体。
  /// 文件缺失、不可读或超限时跳过对应条目，不影响其余数据导出。
  Future<BackupAppearance> _exportAppearance(
    SharedPreferences prefs,
  ) async {
    final background = await _encodeAppearanceFile(
      prefs.getString('customBackgroundPath'),
      maxBytes: _maxImageBytes,
    );
    final playerDetail = await _encodeAppearanceFile(
      prefs.getString('playerDetailCustomImagePath'),
      maxBytes: _maxImageBytes,
    );
    // 字体没有路径设置项：family 非空即视为启用，文件固定在
    // appearance/custom_font.ttf。
    final font = (prefs.getString('fontFamily') ?? '').trim().isEmpty
        ? null
        : await _encodeAppearanceFile(
            await customFontFilePath(),
            maxBytes: _maxFontBytes,
          );
    return BackupAppearance(
      background: background,
      playerDetail: playerDetail,
      font: font,
    );
  }

  /// 读取单个外观文件并编码为 base64 条目；路径为空、文件不存在、
  /// 读取失败或超过 [maxBytes] 时返回 null。
  Future<BackupAppearanceFile?> _encodeAppearanceFile(
    String? path, {
    required int maxBytes,
  }) async {
    if (path == null || path.isEmpty) return null;
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty || bytes.length > maxBytes) return null;
      return BackupAppearanceFile(
        name: p.basename(path),
        base64: base64Encode(bytes),
      );
    } on FileSystemException {
      return null;
    }
  }

  /// 解析并校验备份里的单个外观文件条目：文件名必须安全（防路径
  /// 穿越）、base64 可解码且不超过 [maxBytes]，否则返回 null 跳过。
  BackupAppearanceFile? _decodeAppearanceEntry(
    Object? raw, {
    required int maxBytes,
  }) {
    if (raw is! Map) return null;
    final name = raw['name'];
    final base64Text = raw['base64'];
    if (name is! String || base64Text is! String || base64Text.isEmpty) {
      return null;
    }
    if (!_isSafeAppearanceFileName(name)) return null;
    try {
      final bytes = base64Decode(base64Text);
      if (bytes.isEmpty || bytes.length > maxBytes) return null;
    } on FormatException {
      return null;
    }
    return BackupAppearanceFile(name: name, base64: base64Text);
  }

  /// 读取 plugins 目录下全部插件脚本（文件名即插件 id）。
  Future<Map<String, String>> _readPluginSources() async {
    final dir = Directory(p.join(await resolveAppDataDir(), 'plugins'));
    if (!dir.existsSync()) return const {};
    final sources = <String, String>{};
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      if (p.extension(entity.path).toLowerCase() != '.js') continue;
      try {
        sources[p.basenameWithoutExtension(entity.path)] =
            await entity.readAsString();
      } on FileSystemException {
        // 单个脚本读取失败时跳过，不影响其余数据导出。
      }
    }
    return sources;
  }

  /// 从 Rust 导出曲库用户数据表（songs/library_folders/artists 等）。
  /// 本地收藏与歌单歌曲依赖这些缓存元数据才能在恢复后正常显示；
  /// 导出失败时抛 [BackupException]（曲库缺失会让本地歌曲恢复不完整，
  /// 不应静默跳过）。
  Future<Map<String, dynamic>> _exportLibrary() async {
    final dbPath = p.join(await resolveAppDataDir(), 'library.db');
    try {
      final payload = await rust.exportLibraryTables(dbPath: dbPath);
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) return decoded;
      throw const FormatException('unexpected payload');
    } on FormatException {
      throw const BackupException('曲库数据导出失败');
    } catch (e) {
      throw BackupException('曲库数据导出失败：$e');
    }
  }
}
