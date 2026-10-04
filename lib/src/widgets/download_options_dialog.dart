import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../player/android_storage.dart';
import '../plugins/plugin_runtime.dart' show qualityDisplayLabel, qualityTierRank;

/// 下载音质档位（与设置页“下载音质”、批量下载面板一致，低 → 高）。
const List<String> kDownloadQualityOptions = [
  '96k',
  '128k',
  '192k',
  '320k',
  'flac',
  'flac24bit',
  'hires',
  'vinyl',
  'dolby',
  'atmos',
  'atmos_plus',
  'master',
];

/// 下载选项（播放详情页与歌曲列表下载共用）。
class DownloadOptions {
  const DownloadOptions({
    required this.directory,
    required this.quality,
    this.dontAskAgain = false,
    this.writeMetadata = true,
  });

  final String directory;
  final String quality;
  final bool dontAskAgain;

  /// 下载后向音频文件写入元数据标签（标题/艺术家/专辑/歌词/封面）。
  final bool writeMetadata;
}

/// 音质对应的下载大小：有损档位按码率估算（estimated=true），
/// 无损档位为直链实测值。
class QualitySize {
  const QualitySize(this.bytes, {this.estimated = false});

  final int bytes;
  final bool estimated;
}

/// 音质选项的展示标签（与播放页更多菜单共用同一映射）。
String qualityOptionLabel(String quality) => qualityDisplayLabel(quality);

/// 文件大小展示：≥1MB 保留一位小数，其余按 KB 取整。
String formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// 按展示标签去重（flac/lossless/sq 等别名只保留第一个）。
List<String> dedupeQualitiesByLabel(List<String> input) {
  final seenLabels = <String>{};
  final result = <String>[];
  for (final quality in input) {
    if (seenLabels.add(qualityOptionLabel(quality))) result.add(quality);
  }
  return result;
}

/// 把 [quality] 归一到 [available] 中存在的档位（别名映射后回退首个）。
String normalizeQualityValue(String quality, List<String> available) {
  if (available.isEmpty) return quality.trim();
  final value = quality.trim();
  if (available.contains(value)) return value;
  final alias = switch (value.toLowerCase()) {
    'standard' => '128k',
    'lossless' || 'sq' => 'flac',
    'high' => '320k',
    _ => value,
  };
  if (available.contains(alias)) return alias;
  return available.first;
}

const String _probeUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

/// 用 `Range: bytes=0-0` 请求探测直链的真实文件大小（字节）。
/// 关键点：必须带上解析音源时拿到的请求头（Referer/Cookie 等），否则部分
/// CDN 会返回错误页，导致 hi-res/杜比/母带这类直链的大小失真。同时排除
/// HLS 播放列表与错误页等非音频响应；无法确定时返回 null（界面显示“未知”）。
Future<int?> probeDirectFileSize(
  String url,
  Map<String, String> headers,
) async {
  final uri = Uri.tryParse(url);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  final client = http.Client();
  try {
    final request = http.Request('GET', uri);
    // 直链自带的请求头优先（Referer/Cookie/UA 等），缺失时补默认值。
    request.headers.addAll(headers);
    request.headers.putIfAbsent('User-Agent', () => _probeUserAgent);
    request.headers.putIfAbsent('Accept', () => 'audio/*,*/*;q=0.5');
    // Range 与禁用压缩是探测准确性的关键，必须由我们覆盖。
    request.headers['Range'] = 'bytes=0-0';
    request.headers['Accept-Encoding'] = 'identity';
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 10));
    // 206 Partial Content：总大小在 Content-Range 的 `bytes 0-0/<total>` 尾部。
    final contentRange = response.headers['content-range'];
    if (contentRange != null) {
      final total = int.tryParse(contentRange.split('/').last.trim());
      if (total != null && total > 0) return total;
    }
    // 200：服务器忽略了 Range，Content-Length 即整文件大小；需排除播放列表
    // 与错误页，避免把几 KB 的清单/HTML 当成音频大小。
    if (response.statusCode == 200 &&
        !_isNonAudioResponse(response.headers['content-type'], uri)) {
      final length = response.contentLength;
      if (length != null && length > 0) return length;
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    client.close();
  }
}

bool _isNonAudioResponse(String? contentType, Uri uri) {
  final path = uri.path.toLowerCase();
  if (path.endsWith('.m3u8') || path.endsWith('.m3u')) return true;
  final ct = (contentType ?? '').toLowerCase();
  if (ct.isEmpty) return false;
  return ct.contains('mpegurl') ||
      ct.contains('text/html') ||
      ct.contains('text/plain') ||
      ct.contains('application/json') ||
      ct.contains('dash+xml');
}

/// 下载选项弹窗：选择下载位置与音质，可勾选“不再弹出”。
///
/// 音质下拉框左侧显示音质名称、右侧显示该音质的文件大小（有损档位先显示
/// 估算值，实测成功后替换）。播放详情页与歌曲列表下载共用，保证样式一致。
class DownloadOptionsDialog extends StatefulWidget {
  const DownloadOptionsDialog({
    super.key,
    required this.initialDirectory,
    required this.initialQuality,
    required this.qualities,
    this.title = '下载歌曲',
    this.initialWriteMetadata = true,
    this.showSizes = true,
    this.discoverQualities,
    this.estimateSize,
    this.probeSize,
  });

  final String title;
  final String initialDirectory;
  final String initialQuality;

  /// 秒开用的初始音质列表（插件声明的音质 + 当前音质），不含联网探测。
  final List<String> qualities;
  final bool initialWriteMetadata;

  /// 是否在下拉框中显示各档位文件大小（多首歌曲批量下载时无意义，可关闭）。
  final bool showSizes;

  /// 异步补齐插件实际支持的完整音质列表；为 null 时不做补齐。
  final Future<List<String>> Function()? discoverQualities;

  /// 有损档位的即时估算大小（同步，可能为 null）；先显示、后由实测替换。
  final QualitySize? Function(String quality)? estimateSize;

  /// 探测某音质的真实文件大小（字节），供下拉框右侧展示。
  final Future<int?> Function(String quality)? probeSize;

  @override
  State<DownloadOptionsDialog> createState() => _DownloadOptionsDialogState();
}

class _DownloadOptionsDialogState extends State<DownloadOptionsDialog> {
  late final TextEditingController _directoryController;
  late String _directoryValue;
  late List<String> _qualities;
  late String _quality;
  bool _dontAskAgain = false;
  bool _choosingDirectory = false;
  bool _discovering = false;
  String? _error;

  /// 各音质当前展示的大小；null 表示暂无（探测中或失败）。
  final Map<String, QualitySize?> _qualitySizes = {};
  final Set<String> _probingQualities = {};
  final Set<String> _probedQualities = {};

  @override
  void initState() {
    super.initState();
    _directoryValue = widget.initialDirectory;
    _directoryController = TextEditingController(
      text: AndroidStorage.displayPath(widget.initialDirectory),
    );
    _qualities = dedupeQualitiesByLabel(
      widget.qualities.isEmpty ? const ['320k'] : widget.qualities,
    );
    _quality = normalizeQualityValue(widget.initialQuality, _qualities);
    // 先用估算值填位，保证下拉框一打开就有大小可看，随后实测替换。
    for (final quality in _qualities) {
      final estimate = widget.estimateSize?.call(quality);
      if (estimate != null) _qualitySizes[quality] = estimate;
    }
    _probeSizesFor(_qualities);
    unawaited(_startDiscovery());
  }

  /// 在弹窗内异步补齐完整音质列表：完成后合并去重、按档位排序，
  /// 并只为新增档位补发大小探测。
  Future<void> _startDiscovery() async {
    final discover = widget.discoverQualities;
    if (discover == null) return;
    _discovering = true;
    List<String> found;
    try {
      found = await discover();
    } catch (_) {
      if (mounted) setState(() => _discovering = false);
      return;
    }
    if (!mounted) return;
    final merged = dedupeQualitiesByLabel([..._qualities, ...found])..sort((a, b) {
      final rank = qualityTierRank(a).compareTo(qualityTierRank(b));
      return rank != 0 ? rank : a.compareTo(b);
    });
    final added = merged.where((q) => !_qualities.contains(q)).toList();
    for (final quality in added) {
      final estimate = widget.estimateSize?.call(quality);
      if (estimate != null) _qualitySizes[quality] = estimate;
    }
    setState(() {
      _qualities = merged;
      _quality = normalizeQualityValue(_quality, merged);
      _discovering = false;
    });
    _probeSizesFor(added);
  }

  /// 并行实测各音质大小：先展示估算值，实测成功后替换为准确值；实测失败
  /// 时保留估算值，无估算则显示“未知”。不阻塞弹窗交互。
  void _probeSizesFor(List<String> qualities) {
    final probe = widget.probeSize;
    if (probe == null) return;
    for (final quality in qualities) {
      if (_probedQualities.contains(quality) ||
          _probingQualities.contains(quality)) {
        continue;
      }
      _probingQualities.add(quality);
      unawaited(
        probe(quality).then((bytes) {
          if (!mounted) return;
          setState(() {
            _probingQualities.remove(quality);
            _probedQualities.add(quality);
            if (bytes != null && bytes > 0) {
              _qualitySizes[quality] = QualitySize(bytes);
            } else if (!_qualitySizes.containsKey(quality)) {
              _qualitySizes[quality] = null;
            }
          });
        }),
      );
    }
  }

  @override
  void dispose() {
    _directoryController.dispose();
    super.dispose();
  }

  Future<void> _chooseDirectory() async {
    if (_choosingDirectory) return;
    setState(() {
      _choosingDirectory = true;
      _error = null;
    });
    try {
      final selected = Platform.isAndroid
          ? await AndroidStorage.pickDirectory()
          : await FilePicker.platform.getDirectoryPath();
      if (!mounted || selected == null) return;
      _directoryValue = selected;
      final displayPath = AndroidStorage.displayPath(selected);
      _directoryController.text = displayPath;
      _directoryController.selection = TextSelection.collapsed(
        offset: displayPath.length,
      );
      setState(() {});
    } catch (error) {
      if (mounted) setState(() => _error = '选择文件夹失败：$error');
    } finally {
      if (mounted) setState(() => _choosingDirectory = false);
    }
  }

  void _submit() {
    final directory = _directoryValue.trim();
    if (directory.isEmpty) {
      setState(() => _error = '请输入或选择下载文件夹');
      return;
    }
    Navigator.pop(
      context,
      DownloadOptions(
        directory: directory,
        quality: _quality,
        dontAskAgain: _dontAskAgain,
        writeMetadata: widget.initialWriteMetadata,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '下载位置',
                  style: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _directoryController,
                        maxLines: 1,
                        style: const TextStyle(fontSize: 13),
                        onChanged: (value) {
                          _directoryValue = value;
                          if (_error != null) setState(() => _error = null);
                        },
                        decoration: const InputDecoration(
                          isDense: true,
                          hintText: '/storage/emulated/0/Music',
                          prefixIcon: Icon(Icons.folder_outlined, size: 19),
                          prefixIconConstraints: BoxConstraints(minWidth: 38),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 11,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      height: 40,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 11),
                        ),
                        onPressed: _choosingDirectory ? null : _chooseDirectory,
                        icon: _choosingDirectory
                            ? const SizedBox.square(
                                dimension: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.folder_open_rounded, size: 18),
                        label: Text(
                          _choosingDirectory ? '选择中' : '选择',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Text(
                      '下载音质',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (_discovering) ...[
                      const SizedBox(width: 8),
                      const SizedBox.square(
                        dimension: 12,
                        child: CircularProgressIndicator(strokeWidth: 1.6),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                _buildQualityDropdown(context),
                CheckboxListTile(
                  value: _dontAskAgain,
                  onChanged: (value) =>
                      setState(() => _dontAskAgain = value == true),
                  contentPadding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('不再弹出此窗口', style: TextStyle(fontSize: 13)),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(fontSize: 12, color: scheme.error),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('开始下载')),
      ],
    );
  }

  /// 音质下拉框：沿用全局 InputDecoration 主题（填充圆角），与上方
  /// 「下载位置」输入框风格一致；左侧音质名称，右侧该音质文件大小。
  Widget _buildQualityDropdown(BuildContext context) {
    return DropdownButtonFormField<String>(
      // 音质列表异步补齐后重建表单字段，避免内部选中值停留在旧列表。
      key: ValueKey(_qualities.join('|')),
      initialValue: _quality,
      isDense: true,
      isExpanded: true,
      decoration: const InputDecoration(
        isDense: true,
        prefixIcon: Icon(Icons.graphic_eq_rounded, size: 19),
        prefixIconConstraints: BoxConstraints(minWidth: 38),
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 11),
      ),
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 13),
      items: [
        for (final quality in _qualities)
          DropdownMenuItem<String>(
            value: quality,
            child: _buildQualityRow(quality),
          ),
      ],
      onChanged: (value) {
        if (value != null) setState(() => _quality = value);
      },
    );
  }

  Widget _buildQualityRow(String quality) {
    return Row(
      children: [
        Expanded(
          child: Text(
            qualityOptionLabel(quality),
            style: const TextStyle(fontSize: 13),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (widget.showSizes) ...[
          const SizedBox(width: 12),
          _buildSizeTrailing(quality),
        ],
      ],
    );
  }

  /// 右侧文件大小：已有估算/实测值直接显示（估算前缀 ≈）；尚无值时，
  /// 探测中显示进度圈，探测结束仍无值则显示“未知”。
  Widget _buildSizeTrailing(String quality) {
    final size = _qualitySizes[quality];
    if (size == null) {
      if (_probingQualities.contains(quality)) {
        return const SizedBox.square(
          dimension: 12,
          child: CircularProgressIndicator(strokeWidth: 1.6),
        );
      }
      return Text(
        '未知',
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );
    }
    final text = '${size.estimated ? '≈' : ''}${formatFileSize(size.bytes)}';
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}