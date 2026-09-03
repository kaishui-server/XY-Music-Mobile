import 'dart:convert';

import '../rust/api.dart';
import 'native_storage_permission.dart';

/// 一次扫描的进度快照。
class ScanProgress {
  const ScanProgress({
    required this.doneFolders,
    required this.totalFolders,
    required this.foundSongs,
  });

  /// 已完成的目录数。
  final int doneFolders;

  /// 参与扫描的目录总数。
  final int totalFolders;

  /// 截至当前累计扫描到的歌曲数。
  final int foundSongs;
}

/// 一次扫描的结果摘要。
class ScanSummary {
  const ScanSummary({
    required this.foundSongs,
    required this.errors,
    required this.canceled,
  });

  /// 累计扫描入库的歌曲数。
  final int foundSongs;

  /// 各目录的失败原因（路径: 错误），单目录失败不阻断其它目录。
  final List<String> errors;

  /// 是否被新的扫描取代而中断。
  final bool canceled;
}

/// 本地音乐扫描编排器。
///
/// 设计参考 MusicFree 的 `localMusicSheet.ts`：
/// - **令牌取消**：每次扫描领取自增令牌，新扫描自动作废进行中的旧扫描
///   （对应 MusicFree 的 importToken 机制）；
/// - **目录级容错**：单个目录读取/扫描失败记录后继续下一个目录，
///   不让一个坏目录毁掉整次扫描（对应 MusicFree 的
///   `catch { dirFiles = [] }`）；
/// - **权限预检**：扫描前通过原生态权限桥（`NativeStoragePermission`）
///   按系统版本申请真正所需的权限，避免 Rust 侧 read_dir 被 EACCES
///   拒绝后才报错。
///
/// 元数据解析与入库由 Rust 侧 `scanMusicFolder`（lofty + SQLite 增量
/// diff）作为原子能力完成，等价于 MusicFree 架构中 native 层的
/// `getMediaMeta`。
class LocalMusicScanner {
  int _token = 0;

  /// 取消进行中的扫描（下一次 scanAll 也会自动作废旧的）。
  void cancel() => _token++;

  /// 依次扫描全部目录，返回结果摘要。
  ///
  /// - 权限未授予时抛出（文案已按系统版本适配）；
  /// - 目录列表为空时跳过权限预检，直接返回空结果。
  Future<ScanSummary> scanAll({
    required String dbPath,
    required List<String> folders,
    required List<String> allowedFormats,
    int? minimumDurationSeconds,
    void Function(ScanProgress progress)? onProgress,
  }) async {
    final token = ++_token;

    if (folders.isEmpty) {
      return const ScanSummary(foundSongs: 0, errors: [], canceled: false);
    }

    // 扫描前预检权限：未授权时直接失败，给出真实原因，而不是让
    // 每个目录都在 Rust 侧报 EACCES。
    if (!await NativeStoragePermission.ensure()) {
      throw Exception(await NativeStoragePermission.deniedHint);
    }

    final errors = <String>[];
    var found = 0;
    for (var i = 0; i < folders.length; i++) {
      if (token != _token) {
        // 已被更新的扫描取代，立即让位。
        return ScanSummary(
          foundSongs: found,
          errors: errors,
          canceled: true,
        );
      }
      try {
        final songsJson = await scanMusicFolder(
          dbPath: dbPath,
          folderPath: folders[i],
          minimumDurationSeconds: minimumDurationSeconds,
          allowedFormats: allowedFormats,
        );
        found += (jsonDecode(songsJson) as List).length;
      } catch (e) {
        // 单目录失败不阻断其它目录（MusicFree readDir 容错同款）。
        errors.add('${folders[i]}: $e');
      }
      onProgress?.call(ScanProgress(
        doneFolders: i + 1,
        totalFolders: folders.length,
        foundSongs: found,
      ));
    }
    return ScanSummary(foundSongs: found, errors: errors, canceled: false);
  }
}
