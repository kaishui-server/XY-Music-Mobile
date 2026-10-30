import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../src/library/library_provider.dart';
import '../../src/rust/api.dart';
import '../../src/widgets/cover_search_sheet.dart';
import '../../src/widgets/top_notice.dart';

/// 保存封面到系统相册的原生桥（与播放页分享图共用同一通道）。
const _galleryChannel = MethodChannel('com.xymusic.mobile/gallery');

/// 编辑歌曲信息页：读取音频文件 tag 回填表单，支持编辑标题/歌手/专辑/
/// 专辑歌手/年份/音轨/碟号/歌词与封面，保存时写回文件 tag 并触发音乐库
/// 重新扫描（扫描按文件 mtime 增量 diff，只有被编辑的文件会重读）。
///
/// 仅本地文件可编辑；网络歌曲不进入本页（列表菜单保持只读「歌曲信息」）。
class SongEditPage extends ConsumerStatefulWidget {
  const SongEditPage({super.key, required this.songPath});

  final String songPath;

  static Future<void> open(BuildContext context, String songPath) {
    return Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => SongEditPage(songPath: songPath),
      ),
    );
  }

  @override
  ConsumerState<SongEditPage> createState() => _SongEditPageState();
}

class _SongEditPageState extends ConsumerState<SongEditPage> {
  final _title = TextEditingController();
  final _artist = TextEditingController();
  final _album = TextEditingController();
  final _albumArtist = TextEditingController();
  final _year = TextEditingController();
  final _track = TextEditingController();
  final _disc = TextEditingController();
  final _lyrics = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  Uint8List? _coverBytes;
  String _coverMime = '';
  bool _coverChanged = false;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    for (final controller in [
      _title,
      _artist,
      _album,
      _albumArtist,
      _year,
      _track,
      _disc,
      _lyrics,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _toast(String message, {XyNoticeType type = XyNoticeType.info}) {
    if (!mounted) return;
    XyNotice.show(context, message: message, type: type);
  }

  Future<void> _load() async {
    try {
      final json = await readAudioMetadata(filePath: widget.songPath);
      final meta = jsonDecode(json) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _title.text = meta['title']?.toString() ?? '';
        _artist.text = meta['artist']?.toString() ?? '';
        _album.text = meta['album']?.toString() ?? '';
        _albumArtist.text = meta['albumArtist']?.toString() ?? '';
        _year.text = meta['year']?.toString() ?? '';
        _track.text = meta['trackNumber']?.toString() ?? '';
        _disc.text = meta['discNumber']?.toString() ?? '';
        _lyrics.text = meta['lyrics']?.toString() ?? '';
        final cover = meta['cover'];
        if (cover is Map) {
          final data = cover['data'];
          if (data is List && data.isNotEmpty) {
            _coverBytes = Uint8List.fromList(data.cast<int>());
            _coverMime = cover['mime']?.toString() ?? 'image/jpeg';
          }
        }
        _searchQuery =
            '${_artist.text.trim()} ${_title.text.trim()}'.trim();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast('读取歌曲信息失败：$e', type: XyNoticeType.error);
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
      setState(() {
        _coverBytes = bytes;
        _coverMime = _mimeFromName(result!.files.single.name);
        _coverChanged = true;
      });
    } catch (e) {
      _toast('选择图片失败：$e', type: XyNoticeType.error);
    }
  }

  Future<void> _searchCover() async {
    final url = await showCoverSearchSheet(context, initialQuery: _searchQuery);
    if (url == null || !mounted) return;
    try {
      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        throw Exception('HTTP ${response.statusCode}');
      }
      final contentType = response.headers['content-type'] ?? '';
      setState(() {
        _coverBytes = response.bodyBytes;
        _coverMime = contentType.contains('png') ? 'image/png' : 'image/jpeg';
        _coverChanged = true;
      });
      _toast('已关联封面，记得保存');
    } catch (e) {
      _toast('封面下载失败：$e', type: XyNoticeType.error);
    }
  }

  Future<void> _viewCover() async {
    final bytes = _coverBytes;
    if (bytes == null) return;
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
  }

  Future<void> _saveCoverToGallery() async {
    final bytes = _coverBytes;
    if (bytes == null) return;
    final fileName =
        'xy_music_cover_${DateTime.now().millisecondsSinceEpoch}'
        '${_coverMime.contains('png') ? '.png' : '.jpg'}';
    try {
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
      _toast(saved ? '封面已保存到相册' : '未保存', type: XyNoticeType.success);
    } catch (e) {
      _toast('保存失败：$e', type: XyNoticeType.error);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    final title = _title.text.trim();
    if (title.isEmpty) {
      _toast('标题不能为空', type: XyNoticeType.warning);
      return;
    }
    setState(() => _saving = true);
    try {
      final request = <String, dynamic>{'filePath': widget.songPath};
      void putText(String key, String value) {
        if (value.trim().isNotEmpty) request[key] = value.trim();
      }

      putText('title', _title.text);
      putText('artist', _artist.text);
      putText('album', _album.text);
      putText('albumArtist', _albumArtist.text);
      putText('year', _year.text);
      putText('trackNumber', _track.text);
      putText('discNumber', _disc.text);
      if (_lyrics.text.trim().isNotEmpty) request['lyrics'] = _lyrics.text;
      final cover = _coverBytes;
      if (cover != null && _coverChanged) {
        request['coverData'] = cover;
        request['coverMime'] = _coverMime.isEmpty ? 'image/jpeg' : _coverMime;
      }
      await writeAudioMetadata(requestJson: jsonEncode(request));
      if (!mounted) return;
      _toast('已保存，正在更新音乐库', type: XyNoticeType.success);
      // 写 tag 会更新文件 mtime，后台增量重扫让库记录（标题/歌手/封面
      // 缩略图）跟上编辑结果；不阻塞返回。
      unawaited(
        ref
            .read(libraryProvider.notifier)
            .scanAllFolders()
            .catchError((_) => 0),
      );
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('保存失败：$e', type: XyNoticeType.error);
    }
  }

  String _mimeFromName(String name) =>
      name.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('编辑歌曲信息'),
        actions: [
          IconButton(
            tooltip: '保存',
            onPressed: _loading || _saving ? null : _save,
            icon: _saving
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check_rounded),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                _buildCoverSection(scheme),
                const SizedBox(height: 20),
                _buildTextField(_title, '标题', '歌曲标题', autofocus: false),
                _buildTextField(_artist, '歌手', '歌手名'),
                _buildTextField(_album, '专辑', '专辑名'),
                _buildTextField(_albumArtist, '专辑歌手', '专辑歌手'),
                Row(
                  children: [
                    Expanded(
                      child: _buildTextField(_year, '年份', '如 2024'),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildTextField(_track, '音轨', '音轨号'),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildTextField(_disc, '碟号', '碟号'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _lyrics,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText: '歌词',
                    hintText: '纯文本或 LRC 歌词',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildCoverSection(ColorScheme scheme) {
    final bytes = _coverBytes;
    return Column(
      children: [
        GestureDetector(
          onTap: bytes == null ? null : _viewCover,
          child: Container(
            width: 168,
            height: 168,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: scheme.surfaceContainerHighest,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: .12),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: bytes != null
                  ? Image.memory(bytes, fit: BoxFit.cover)
                  : Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.music_note_rounded,
                          size: 44,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '无内嵌封面',
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          alignment: WrapAlignment.center,
          children: [
            _coverAction(
              scheme,
              Icons.zoom_in_rounded,
              '查看大图',
              bytes != null,
              _viewCover,
            ),
            _coverAction(
              scheme,
              Icons.save_alt_rounded,
              '保存到相册',
              bytes != null,
              _saveCoverToGallery,
            ),
            _coverAction(
              scheme,
              Icons.image_search_rounded,
              '搜索封面',
              true,
              _searchCover,
            ),
            _coverAction(
              scheme,
              Icons.photo_library_outlined,
              '从相册选择',
              true,
              _pickFromGallery,
            ),
          ],
        ),
      ],
    );
  }

  Widget _coverAction(
    ColorScheme scheme,
    IconData icon,
    String label,
    bool enabled,
    VoidCallback onTap,
  ) {
    final color = enabled ? scheme.primary : scheme.onSurfaceVariant.withValues(alpha: .4);
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: enabled ? onTap : null,
      child: Container(
        width: 76,
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(fontSize: 11, color: color),
              maxLines: 1,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTextField(
    TextEditingController controller,
    String label,
    String hint, {
    bool autofocus = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextField(
      controller: controller,
      autofocus: autofocus,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
    ),
  );
}
