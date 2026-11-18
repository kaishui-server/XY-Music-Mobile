import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../core/db_path.dart';
import '../widgets/cover_search_sheet.dart';
import '../widgets/top_notice.dart';
import 'online_cover_overrides.dart';

/// 保存封面到系统相册的原生桥（与在线封面编辑页共用同一通道）。
const MethodChannel _galleryChannel = MethodChannel('com.xymusic.mobile/gallery');

/// 封面编辑四动作的共用实现。
///
/// 播放详情页「编辑封面」下拉菜单与在线封面编辑页共用同一套逻辑，
/// 保证「查看大图 / 保存到相册 / 搜索封面（跨插件）/ 从相册选择」在各处
/// 行为一致：结果统一落盘为应用内图片并以覆盖表记录，展示端优先取覆盖值。
class SongCoverEditor {
  SongCoverEditor({
    required this.songPath,
    required this.title,
    required this.artist,
    required this.originalCoverUrl,
    this.pluginId,
    this.durationMs = 0,
  });

  final String songPath;
  final String title;
  final String artist;
  final String? originalCoverUrl;

  /// 歌曲所属插件 id：封面搜索时该插件的结果优先。
  final String? pluginId;

  /// 歌曲时长（毫秒）：封面搜索时用于时长匹配打分。
  final int durationMs;

  /// 当前生效封面地址：覆盖值优先，否则原网络封面。
  String? get effectiveUrl => resolveOnlineCoverUrl(originalCoverUrl, songPath);

  /// 是否已存在自定义封面。
  bool get hasOverride {
    final resolved = resolveOnlineCoverUrl(null, songPath);
    return resolved != null && resolved.isNotEmpty;
  }

  /// 拿到当前生效封面的字节（大图查看/保存到相册共用）。
  Future<Uint8List?> loadEffectiveBytes() async {
    final url = effectiveUrl;
    if (url == null || url.isEmpty) return null;
    if (url.startsWith('file://')) {
      final file = File.fromUri(Uri.parse(url));
      if (!file.existsSync()) return null;
      return await file.readAsBytes();
    }
    final response = await http
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
      throw Exception('HTTP ${response.statusCode}');
    }
    return response.bodyBytes;
  }

  /// 查看大图：全屏 + 双指缩放。
  Future<void> viewLarge(BuildContext context) async {
    try {
      final bytes = await loadEffectiveBytes();
      if (!context.mounted) return;
      if (bytes == null) {
        _toast(context, '暂无封面');
        return;
      }
      await showDialog<void>(
        context: context,
        useRootNavigator: true,
        builder: (dialogContext) => Dialog.fullscreen(
          backgroundColor: Colors.black87,
          child: Stack(
            children: [
              Center(
                child: InteractiveViewer(
                  maxScale: 5,
                  child: Image.memory(bytes, fit: BoxFit.contain),
                ),
              ),
              Positioned(
                top: MediaQuery.paddingOf(dialogContext).top + 8,
                right: 12,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.pop(dialogContext),
                ),
              ),
            ],
          ),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      _toast(context, '封面加载失败：$e', type: XyNoticeType.error);
    }
  }

  /// 保存到相册（Android 走原生通道，桌面走另存为）。
  Future<bool> saveToGallery(BuildContext context) async {
    try {
      final bytes = await loadEffectiveBytes();
      if (!context.mounted) return false;
      if (bytes == null) {
        _toast(context, '暂无封面');
        return false;
      }
      final fileName =
          'xy_music_cover_${DateTime.now().millisecondsSinceEpoch}.jpg';
      bool saved;
      if (Platform.isAndroid) {
        saved =
            await _galleryChannel.invokeMethod<bool>('saveImage', {
              'bytes': bytes,
              'fileName': fileName,
            }) ??
            false;
      } else {
        final path = await FilePicker.platform.saveFile(
          dialogTitle: '保存封面',
          fileName: fileName,
        );
        if (path != null && path.isNotEmpty) {
          await File(path).writeAsBytes(bytes);
          saved = true;
        } else {
          saved = false;
        }
      }
      if (!context.mounted) return saved;
      _toast(
        context,
        saved ? '封面已保存到相册' : '未保存',
        type: saved ? XyNoticeType.success : XyNoticeType.info,
      );
      return saved;
    } catch (e) {
      if (!context.mounted) return false;
      _toast(context, '保存失败：$e', type: XyNoticeType.error);
      return false;
    }
  }

  /// 跨插件搜索封面并写入覆盖表。
  ///
  /// 检索范围与「关联歌词」一致：所有已启用插件并发搜索，命中后下载
  /// 字节落盘，避免只在网络可达时才显示封面。
  Future<bool> searchCover(BuildContext context) async {
    final query = [artist, title]
        .where((value) => value.trim().isNotEmpty)
        .join(' ')
        .trim();
    final url = await showCoverSearchSheet(
      context,
      initialQuery: query.isEmpty ? title : query,
      pluginId: pluginId,
      targetTitle: title,
      targetArtist: artist,
      targetDurationMs: durationMs,
    );
    if (url == null || !context.mounted) return false;
    try {
      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        throw Exception('HTTP ${response.statusCode}');
      }
      await applyBytes(response.bodyBytes);
      if (!context.mounted) return true;
      _toast(context, '封面已更新', type: XyNoticeType.success);
      return true;
    } catch (e) {
      if (!context.mounted) return false;
      _toast(context, '封面下载失败：$e', type: XyNoticeType.error);
      return false;
    }
  }

  /// 从相册（文件选择器）挑一张图作为封面。
  Future<bool> pickFromGallery(BuildContext context) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true,
      );
      final bytes = result?.files.singleOrNull?.bytes;
      if (bytes == null || bytes.isEmpty) return false; // 用户取消
      await applyBytes(bytes);
      if (!context.mounted) return true;
      _toast(context, '封面已更新', type: XyNoticeType.success);
      return true;
    } catch (e) {
      if (!context.mounted) return false;
      _toast(context, '选择图片失败：$e', type: XyNoticeType.error);
      return false;
    }
  }

  /// 写入自定义封面：字节落盘到应用目录后记录覆盖表。
  Future<void> applyBytes(Uint8List bytes) async {
    final appDir = await resolveAppDataDir();
    final dir = Directory('$appDir/song_covers');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final file = File(
      '${dir.path}/online_${DateTime.now().millisecondsSinceEpoch}.jpg',
    );
    await file.writeAsBytes(bytes);
    await setOnlineSongCover(songPath, 'file://${file.path}');
  }

  /// 清除自定义封面，回到来源插件提供的原封面。
  Future<void> reset(BuildContext context) async {
    await setOnlineSongCover(songPath, '');
    if (!context.mounted) return;
    _toast(context, '已恢复原封面', type: XyNoticeType.success);
  }

  void _toast(
    BuildContext context,
    String message, {
    XyNoticeType type = XyNoticeType.info,
  }) {
    XyNotice.show(context, message: message, type: type);
  }
}
