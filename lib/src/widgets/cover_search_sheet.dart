import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../plugins/plugin_runtime.dart';
import 'top_notice.dart';

/// 封面搜索结果项。
class CoverSearchResult {
  const CoverSearchResult({
    required this.title,
    required this.artist,
    required this.url,
    this.source = '',
    this.pluginId = '',
    this.durationMs = 0,
    this.isFallback = false,
  });

  final String title;
  final String artist;
  final String url;

  /// 结果来源标签：插件名（或 iTunes 兜底时的「iTunes」）。
  final String source;

  /// 命中该结果的插件 id（兜底来源为空）。
  final String pluginId;

  /// 该候选自身时长（毫秒），用于与当前歌曲做时长匹配打分。
  final int durationMs;

  /// 是否来自兜底数据源（全部插件未检索到封面时）。
  final bool isFallback;
}

/// 弹出「编辑封面」的跨插件搜索面板。
///
/// 检索策略与「关联歌词」保持一致：向**所有**已启用插件并发搜索，哪个
/// 插件先返回就先展示它的结果，顶部实时显示「已检索 x/y 个插件」；
/// 候选按「标题 > 时长（秒级完全一致）> 作者」打分排序，同分时歌曲所属
/// 插件（[pluginId]）优先。全部插件都没有封面时才回退 iTunes 曲库。
///
/// 返回 null 表示用户取消；返回非空 URL 表示用户选中了该封面（调用方
/// 自行下载字节或直接记录 URL）。
Future<String?> showCoverSearchSheet(
  BuildContext context, {
  required String initialQuery,
  String? pluginId,
  String? targetTitle,
  String? targetArtist,
  int targetDurationMs = 0,
  String sheetTitle = '编辑封面',
}) {
  return showModalBottomSheet<String>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _CoverSearchSheet(
      initialQuery: initialQuery,
      pluginId: pluginId,
      targetTitle: targetTitle,
      targetArtist: targetArtist,
      targetDurationMs: targetDurationMs,
      sheetTitle: sheetTitle,
    ),
  );
}

class _CoverSearchSheet extends ConsumerStatefulWidget {
  const _CoverSearchSheet({
    required this.initialQuery,
    required this.sheetTitle,
    this.pluginId,
    this.targetTitle,
    this.targetArtist,
    this.targetDurationMs = 0,
  });

  final String initialQuery;
  final String sheetTitle;

  /// 歌曲来源插件 id：同分候选里该插件的结果优先。
  final String? pluginId;
  final String? targetTitle;
  final String? targetArtist;
  final int targetDurationMs;

  @override
  ConsumerState<_CoverSearchSheet> createState() => _CoverSearchSheetState();
}

class _CoverSearchSheetState extends ConsumerState<_CoverSearchSheet> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialQuery,
  );
  bool _searching = false;
  bool _downloading = false;
  List<CoverSearchResult> _results = const [];
  String? _error;

  /// 跨插件进度：已完成检索的插件数 / 已启用的插件总数。
  int _completedPlugins = 0;
  int _totalPlugins = 0;

  /// 当前结果的检索来源说明（用于面板底部提示）。
  String _sourceHint = '';

  /// 请求序号：连续搜索时丢弃过期结果。
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    // 初始关键词非空时自动搜索一次，省去用户手动点击。
    if (widget.initialQuery.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _search());
    }
  }

  @override
  void dispose() {
    _requestId++;
    _controller.dispose();
    super.dispose();
  }

  String get _targetTitle => (widget.targetTitle ?? '').trim();

  String get _targetArtist => (widget.targetArtist ?? '').trim();

  int get _targetDurationMs => widget.targetDurationMs;

  Future<void> _search() async {
    final query = _controller.text.trim();
    if (query.isEmpty || _searching) return;
    final requestId = ++_requestId;
    setState(() {
      _searching = true;
      _error = null;
      _sourceHint = '';
      _results = const [];
      _completedPlugins = 0;
      _totalPlugins = 0;
    });
    try {
      final List<EnabledMusicPlugin> plugins;
      try {
        plugins = await ref.read(enabledMusicPluginsProvider.future);
      } catch (_) {
        if (!mounted || requestId != _requestId) return;
        await _applyFallback(query, requestId);
        return;
      }
      if (!mounted || requestId != _requestId) return;
      if (plugins.isEmpty) {
        await _applyFallback(query, requestId);
        return;
      }

      final preferred = widget.pluginId;
      final ordered = <EnabledMusicPlugin>[
        ...plugins.where((p) => p.id == preferred),
        ...plugins.where((p) => p.id != preferred),
      ];
      setState(() => _totalPlugins = ordered.length);

      final runtime = ref.read(pluginRuntimeProvider);
      final collected = <CoverSearchResult>[];
      final seen = <String>{};
      var completed = 0;

      // 并发检索全部插件：单个插件慢或失败都不阻塞其它插件的结果上屏。
      await Future.wait(
        ordered.map((plugin) async {
          var songs = const <PluginSearchSong>[];
          try {
            songs = await runtime
                .search(plugin, query)
                .timeout(const Duration(seconds: 20));
          } catch (_) {
            // 单个插件失败不影响整体：继续等待其它插件。
          }
          completed++;
          if (!mounted || requestId != _requestId) return;
          for (final song in songs) {
            final url = _hiresCover(song.coverUrl);
            if (url.isEmpty || !seen.add(url)) continue;
            collected.add(
              CoverSearchResult(
                title: song.title.isEmpty ? query : song.title,
                artist: song.artist,
                url: url,
                pluginId: plugin.id,
                durationMs: song.durationMs,
                source: song.platform.isEmpty
                    ? plugin.name
                    : '${plugin.name}·${song.platform}',
              ),
            );
          }
          final sorted = [...collected]..sort(_compareResults);
          setState(() {
            _completedPlugins = completed;
            _results = sorted;
          });
        }),
      );
      if (!mounted || requestId != _requestId) return;
      if (collected.isEmpty) {
        await _applyFallback(query, requestId);
        return;
      }
      setState(() {
        _searching = false;
        _completedPlugins = completed;
        _sourceHint = '已检索 ${ordered.length} 个已启用插件';
      });
    } catch (e) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _searching = false;
        _results = const [];
        _error = '搜索失败：$e';
      });
    }
  }

  /// 全部插件未命中时回退 iTunes 曲库。
  Future<void> _applyFallback(String query, int requestId) async {
    try {
      final fallback = await _searchFromItunes(query);
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _results = fallback;
        _searching = false;
        _sourceHint = fallback.isEmpty ? '' : '插件未命中，已回退 iTunes 曲库';
        if (fallback.isEmpty) _error = '未找到相关封面，换个关键词试试';
      });
    } catch (e) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _searching = false;
        _results = const [];
        _error = '未找到相关封面，换个关键词试试';
      });
    }
  }

  String _normalize(String text) =>
      text.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();

  /// 封面候选排序打分：标题 > 时长（秒级完全一致）> 作者。
  int _coverScore(CoverSearchResult result) {
    var score = 0;
    final targetTitle = _normalize(_targetTitle);
    final title = _normalize(result.title);
    if (title.isNotEmpty && targetTitle.isNotEmpty) {
      if (title == targetTitle) {
        score += 3;
      } else if (title.contains(targetTitle) || targetTitle.contains(title)) {
        score += 2;
      }
    }
    final targetSeconds = _targetDurationMs ~/ 1000;
    final seconds = result.durationMs ~/ 1000;
    if (targetSeconds > 0 && seconds == targetSeconds) score += 2;
    final targetArtist = _normalize(_targetArtist);
    final artist = _normalize(result.artist);
    if (artist.isNotEmpty &&
        targetArtist.isNotEmpty &&
        (artist.contains(targetArtist) || targetArtist.contains(artist))) {
      score += 1;
    }
    return score;
  }

  int _compareResults(CoverSearchResult a, CoverSearchResult b) {
    final score = _coverScore(b).compareTo(_coverScore(a));
    if (score != 0) return score;
    final preferred = widget.pluginId;
    if (preferred != null && preferred.isNotEmpty) {
      final aPreferred = a.pluginId == preferred ? 0 : 1;
      final bPreferred = b.pluginId == preferred ? 0 : 1;
      if (aPreferred != bPreferred) return aPreferred.compareTo(bPreferred);
    }
    final source = a.source.compareTo(b.source);
    return source != 0 ? source : a.url.compareTo(b.url);
  }

  /// 兜底：iTunes Search API（无需鉴权，artwork CDN 大陆可直连）。
  Future<List<CoverSearchResult>> _searchFromItunes(String query) async {
    final uri = Uri.https('itunes.apple.com', '/search', {
      'term': query,
      'media': 'music',
      'entity': 'song',
      'limit': '24',
    });
    final response = await http
        .get(uri)
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    final results = <CoverSearchResult>[
      for (final item in (body['results'] as List? ?? const []))
        if (item is Map)
          CoverSearchResult(
            title: item['trackName']?.toString() ?? '',
            artist: item['artistName']?.toString() ?? '',
            url: (item['artworkUrl100']?.toString() ?? '').replaceFirst(
              '100x100',
              '600x600',
            ),
            durationMs: (item['trackTimeMillis'] as num?)?.toInt() ?? 0,
            source: 'iTunes',
            isFallback: true,
          ),
    ].where((item) => item.url.isNotEmpty).toList();
    return results;
  }

  /// 把插件返回的缩略封面抬到可用大图尺寸。
  ///
  /// 洛雪/大部分插件给的是 `?param=300y300` 或 `/100x100/` 这类缩略地址，
  /// 直接当详情页封面会糊；统一替换为 800 级别（服务端不支持时按原图
  /// 返回，不会失败）。
  String _hiresCover(String url) {
    if (url.isEmpty) return url;
    var out = url.replaceAllMapped(
      RegExp(r'([?&]param=)\d+y\d+'),
      (m) => '${m[1]}800y800',
    );
    out = out.replaceAllMapped(
      RegExp(r'(\d+)x(\d+)bb\.'),
      (m) => '800x800bb.',
    );
    out = out.replaceFirst('/100x100/', '/800x800/');
    return out;
  }

  /// 选中封面：预取字节成功才回传 URL，避免写回时才下载失败。
  Future<void> _pick(CoverSearchResult result) async {
    if (_downloading) return;
    setState(() => _downloading = true);
    try {
      final response = await http
          .get(Uri.parse(result.url))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        throw Exception('图片下载失败（HTTP ${response.statusCode}）');
      }
      if (!mounted) return;
      Navigator.pop(context, result.url);
    } catch (e) {
      if (!mounted) return;
      setState(() => _downloading = false);
      XyNotice.show(context, message: '封面下载失败：$e', type: XyNoticeType.error);
    }
  }

  String _formatDuration(int durationMs) {
    if (durationMs <= 0) return '';
    final seconds = durationMs ~/ 1000;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.78,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                child: Row(
                  children: [
                    Text(
                      widget.sheetTitle,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (_searching)
                      Text(
                        _totalPlugins > 0
                            ? '已检索 $_completedPlugins/$_totalPlugins 个插件'
                            : '正在检索插件…',
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => _search(),
                        decoration: InputDecoration(
                          hintText: '输入歌曲名 / 歌手搜索封面',
                          isDense: true,
                          prefixIcon: const Icon(Icons.search, size: 20),
                          border: const OutlineInputBorder(),
                          suffixIcon: _controller.text.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.close, size: 18),
                                  onPressed: () {
                                    _controller.clear();
                                    setState(() => _results = const []);
                                  },
                                ),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _searching ? null : _search,
                      child: _searching
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('搜索'),
                    ),
                  ],
                ),
              ),
              if (_searching && _totalPlugins > 0)
                LinearProgressIndicator(
                  minHeight: 2,
                  value: _totalPlugins == 0
                      ? null
                      : _completedPlugins / _totalPlugins,
                ),
              const Divider(height: 1),
              Expanded(child: _buildBody(scheme)),
              if (_sourceHint.isNotEmpty && !_searching)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                  child: Text(
                    _sourceHint,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              if (_downloading)
                const Padding(
                  padding: EdgeInsets.all(10),
                  child: SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    if (_searching && _results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _results.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
      );
    }
    if (_results.isEmpty) {
      return Center(
        child: Text(
          '输入关键词搜索封面',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 0.72,
      ),
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final result = _results[index];
        final duration = _formatDuration(result.durationMs);
        return InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => _pick(result),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.network(
                        result.url,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        loadingBuilder: (context, child, progress) =>
                            progress == null
                            ? child
                            : const Center(
                                child: SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              ),
                        errorBuilder: (_, _, _) => Container(
                          color: scheme.surfaceContainerHighest,
                          alignment: Alignment.center,
                          child: Icon(
                            Icons.image_not_supported_outlined,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                    if (result.source.isNotEmpty)
                      Positioned(
                        left: 4,
                        bottom: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: .55),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            result.source,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10,
                              color: result.isFallback
                                  ? Colors.orangeAccent
                                  : Colors.white,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                result.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
              Text(
                duration.isEmpty
                    ? result.artist
                    : '${result.artist} · $duration',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
