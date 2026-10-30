import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../../src/core/db_path.dart';
import '../../src/library/online_cover_overrides.dart';
import '../../src/widgets/cover_search_sheet.dart';
import '../../src/widgets/top_notice.dart';

/// 保存封面到系统相册的原生桥（与播放页分享图共用同一通道）。
const _galleryChannel = MethodChannel('com.xymusic.mobile/gallery');

/// 在线歌曲封面编辑页：在线歌曲没有本地文件可写 tag，封面四操作
/// （查看大图 / 保存到相册 / 搜索并关联封面 / 从相册选择）的结果统一
/// 落盘为应用内图片并以覆盖表记录，展示端（列表/播放页）优先取覆盖值。
class OnlineCoverEditPage extends StatefulWidget {
  const OnlineCoverEditPage({
    super.key,
    required this.songPath,
    required this.title,
    required this.artist,
    required this.originalCoverUrl,
  });

  final String songPath;
  final String title;
  final String artist;
  final String? originalCoverUrl;

  static Future<void> open(
    BuildContext context, {
    required String songPath,
    required String title,
    required String artist,
    required String? coverUrl,
  }) {
    return Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => OnlineCoverEditPage(
          songPath: songPath,
          title: title,
          artist: artist,
          originalCoverUrl: coverUrl,
        ),
      ),
    );
  }

  @override
  State<OnlineCoverEditPage> createState() => _OnlineCoverEditPageState();
}

class _OnlineCoverEditPageState extends State<OnlineCoverEditPage> {
  bool _hasOverride = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _hasOverride = _currentOverride() != null;
  }

  String? _currentOverride() {
    // 只查覆盖表：返回非空即说明该歌曲存在自定义封面。
    final resolved = resolveOnlineCoverUrl(null, widget.songPath);
    return (resolved != null && resolved.isNotEmpty) ? resolved : null;
  }

  void _toast(String message, {XyNoticeType type = XyNoticeType.info}) {
    if (!mounted) return;
    XyNotice.show(context, message: message, type: type);
  }

  /// 当前生效封面地址：覆盖值优先，否则原网络封面。
  String? get _effectiveUrl =>
      resolveOnlineCoverUrl(widget.originalCoverUrl, widget.songPath);

  Future<void> _apply(Uint8List bytes) async {
    setState(() => _busy = true);
    try {
      final appDir = await resolveAppDataDir();
      final dir = Directory('$appDir/song_covers');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final file = File(
        '${dir.path}/online_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      await file.writeAsBytes(bytes);
      await setOnlineSongCover(widget.songPath, 'file://${file.path}');
      if (!mounted) return;
      setState(() => _busy = false);
      _toast('封面已更新', type: XyNoticeType.success);
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _toast('封面保存失败：$e', type: XyNoticeType.error);
    }
  }

  Future<void> _searchCover() async {
    final query = '${widget.artist} ${widget.title}'.trim();
    final url = await showCoverSearchSheet(context, initialQuery: query);
    if (url == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        throw Exception('HTTP ${response.statusCode}');
      }
      await _apply(response.bodyBytes);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _toast('封面下载失败：$e', type: XyNoticeType.error);
    }
  }

  Future<void> _pickFromGallery() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true,
      );
      final bytes = result?.files.singleOrNull?.bytes;
      if (bytes == null || bytes.isEmpty) return; // 用户取消
      await _apply(bytes);
    } catch (e) {
      _toast('选择图片失败：$e', type: XyNoticeType.error);
    }
  }

  /// 拿到当前生效封面的字节（大图查看/保存到相册共用）。
  Future<Uint8List?> _loadEffectiveBytes() async {
    final url = _effectiveUrl;
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

  Future<void> _viewCover() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final bytes = await _loadEffectiveBytes();
      if (!mounted) return;
      setState(() => _busy = false);
      if (bytes == null) {
        _toast('暂无封面');
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
      if (!mounted) return;
      setState(() => _busy = false);
      _toast('封面加载失败：$e', type: XyNoticeType.error);
    }
  }

  Future<void> _saveToGallery() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final bytes = await _loadEffectiveBytes();
      if (bytes == null) {
        if (mounted) setState(() => _busy = false);
        _toast('暂无封面');
        return;
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
      if (!mounted) return;
      setState(() => _busy = false);
      _toast(saved ? '封面已保存到相册' : '未保存', type: XyNoticeType.success);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _toast('保存失败：$e', type: XyNoticeType.error);
    }
  }

  Future<void> _resetCover() async {
    await setOnlineSongCover(widget.songPath, '');
    if (!mounted) return;
    setState(() => _hasOverride = _currentOverride() != null);
    _toast('已恢复原封面', type: XyNoticeType.success);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = _effectiveUrl;
    final hasOverride = _hasOverride;
    return Scaffold(
      appBar: AppBar(title: const Text('编辑封面')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Center(
            child: GestureDetector(
              onTap: _viewCover,
              child: Container(
                width: 200,
                height: 200,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  color: scheme.surfaceContainerHighest,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: .12),
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: url != null && url.isNotEmpty
                      ? (url.startsWith('file://')
                            ? Image.file(
                                File.fromUri(Uri.parse(url)),
                                fit: BoxFit.cover,
                              )
                            : Image.network(
                                url,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => _placeholder(scheme),
                              ))
                      : _placeholder(scheme),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Center(
            child: Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
          ),
          if (widget.artist.trim().isNotEmpty)
            Center(
              child: Text(
                widget.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            alignment: WrapAlignment.center,
            children: [
              _action(scheme, Icons.zoom_in_rounded, '查看大图', _viewCover),
              _action(scheme, Icons.save_alt_rounded, '保存到相册', _saveToGallery),
              _action(scheme, Icons.image_search_rounded, '搜索封面', _searchCover),
              _action(scheme, Icons.photo_library_outlined, '从相册选择', _pickFromGallery),
            ],
          ),
          if (hasOverride) ...[
            const SizedBox(height: 16),
            Center(
              child: TextButton.icon(
                onPressed: _resetCover,
                icon: const Icon(Icons.restart_alt_rounded, size: 18),
                label: const Text('恢复原封面'),
              ),
            ),
          ],
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }

  Widget _placeholder(ColorScheme scheme) => Center(
    child: Icon(
      Icons.music_note_rounded,
      size: 52,
      color: scheme.onSurfaceVariant,
    ),
  );

  Widget _action(
    ColorScheme scheme,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        width: 84,
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: [
            Icon(icon, size: 22, color: scheme.primary),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(fontSize: 11, color: scheme.primary),
              maxLines: 1,
            ),
          ],
        ),
      ),
    );
  }
}
