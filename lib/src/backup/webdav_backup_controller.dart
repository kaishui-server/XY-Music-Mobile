import '../core/settings.dart';
import '../plugins/plugin_runtime.dart';
import 'backup_service.dart';
import 'webdav_client.dart';

/// WebDAV 备份上传结果：[blob] 为本次上传的内容（与本地导出同源），
/// [removedCount] 为「保留最新备份」清理掉的旧备份数量。
class WebdavBackupResult {
  const WebdavBackupResult({required this.blob, required this.removedCount});

  final BackupBlob blob;
  final int removedCount;
}

/// WebDAV 备份业务逻辑（不含任何界面代码）：
///
/// - 备份内容与本地「导出备份」完全同源，统一走
///   [BackupService.buildBackupBlob]，因此两类备份的文件名、结构与
///   勾选项语义完全一致；
/// - 恢复解析与本地「导入备份」同源，统一走
///   [BackupService.decodeBackupText]，确认与写回流程由调用方复用本地
///   的对话框与流程，不另写一套。
///
/// 远端固定使用 [kWebdavBackupDirName] 目录（不存在时自动创建），
/// 备份文件名沿用本地导出格式 `xy_music_backup_yyyyMMdd_HHmmss.json`。
class WebdavBackupController {
  const WebdavBackupController();

  /// 远端备份文件名前缀（与本地导出一致）。
  static const String backupPrefix = 'xy_music_backup_';

  /// 远端备份目录（带尾斜杠，可直接拼接文件名）。
  static String get directory => '$kWebdavBackupDirName/';

  /// 用连接配置构建客户端；必填项缺失时以用户可读文案抛
  /// [WebdavException]。
  WebdavClient buildClient({
    required String serverUrl,
    required String username,
    required String password,
  }) {
    final server = serverUrl.trim();
    final account = username.trim();
    if (server.isEmpty) throw const WebdavException('请先填写服务器 URL');
    if (account.isEmpty) throw const WebdavException('请先填写账号');
    if (password.isEmpty) throw const WebdavException('请先填写密码');
    return WebdavClient(
      serverUrl: server,
      username: account,
      password: password,
    );
  }

  /// 连通性校验（不读写文件）。
  Future<void> verifyConnection(WebdavClient client) => client.ping();

  /// 备份到 WebDAV：确保目录 → 组装内容（与本地导出同源）→ 上传 →
  /// 可选清理旧备份。
  Future<WebdavBackupResult> backup({
    required WebdavClient client,
    required BackupExportOptions options,
    required bool keepLatestOnly,
    void Function(String label)? onProgress,
  }) async {
    await client.ensureDirectory(directory);
    final blob = await const BackupService().buildBackupBlob(options: options);
    onProgress?.call('正在上传备份…');
    await client.uploadFile('$directory${blob.fileName}', blob.json);
    var removed = 0;
    if (keepLatestOnly) {
      onProgress?.call('正在清理旧备份…');
      removed = await pruneOldBackups(client, keepFileName: blob.fileName);
    }
    return WebdavBackupResult(blob: blob, removedCount: removed);
  }

  /// 列出远端备份，按修改时间从新到旧排列。
  ///
  /// 目录尚未创建（还没备份过）不是错误，按「无备份」返回空列表。
  Future<List<WebdavEntry>> listBackups(WebdavClient client) async {
    final List<WebdavEntry> entries;
    try {
      entries = await client.listFiles(directory);
    } on WebdavException catch (error) {
      // 目录还没创建（尚未备份过）按「无备份」处理，不向用户报错。
      // 优先看状态码，文案比较仅作旧版本兜底。
      if (error.statusCode == 404 || error.message == '服务器上不存在该路径') {
        return const [];
      }
      rethrow;
    }
    return entries
        .where((entry) => !entry.isDirectory && isBackupFile(entry.name))
        .toList()
      ..sort((a, b) {
        final left = a.modified ?? DateTime.fromMillisecondsSinceEpoch(0);
        final right = b.modified ?? DateTime.fromMillisecondsSinceEpoch(0);
        return right.compareTo(left);
      });
  }

  /// 下载并解析远端备份（解析逻辑与本地导入完全一致）。
  Future<BackupData> downloadBackup({
    required WebdavClient client,
    required String fileName,
    List<EnabledMusicPlugin> enabledPlugins = const [],
  }) async {
    final text = await client.downloadFile('$directory$fileName');
    return const BackupService().decodeBackupText(
      text,
      enabledPlugins: enabledPlugins,
    );
  }

  /// 删除远端目录内除 [keepFileName] 之外的备份文件，返回删除数量。
  Future<int> pruneOldBackups(
    WebdavClient client, {
    required String keepFileName,
  }) async {
    var removed = 0;
    try {
      final entries = await client.listFiles(directory);
      for (final entry in entries) {
        if (entry.isDirectory) continue;
        if (!isBackupFile(entry.name) || entry.name == keepFileName) continue;
        try {
          await client.deleteFile('$directory${entry.name}');
          removed++;
        } catch (_) {
          // 单个旧备份删除失败不影响本次备份结果。
        }
      }
    } catch (_) {
      // 列目录失败时跳过清理，备份本身已成功，不向用户报错。
    }
    return removed;
  }

  /// 是否为备份文件（与本地导出同名前缀与后缀）。
  static bool isBackupFile(String name) =>
      name.startsWith(backupPrefix) && name.endsWith('.json');

  /// 备份时间展示（本地时区，精确到分钟）。
  static String formatTime(DateTime? time) {
    if (time == null) return '时间未知';
    final local = time.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  /// 备份大小展示。
  static String formatSize(int bytes) {
    if (bytes <= 0) return '大小未知';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
