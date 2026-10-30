import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'top_notice.dart';

/// 封面搜索结果项。
class CoverSearchResult {
  const CoverSearchResult({required this.title, required this.artist, required this.url});

  final String title;
  final String artist;
  final String url;
}

/// 弹出「搜索并关联封面」面板：以歌曲/歌单关键词搜索网络封面，
/// 点选后返回所选封面图 URL（调用方自行下载字节并使用）。
///
/// 返回 null 表示用户取消；返回非空 URL 表示用户选中了该封面。
/// 数据源为 iTunes Search API（无需鉴权，artwork CDN 大陆可直连）。
Future<String?> showCoverSearchSheet(
  BuildContext context, {
  required String initialQuery,
}) {
  return showModalBottomSheet<String>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _CoverSearchSheet(initialQuery: initialQuery),
  );
}

class _CoverSearchSheet extends StatefulWidget {
  const _CoverSearchSheet({required this.initialQuery});

  final String initialQuery;

  @override
  State<_CoverSearchSheet> createState() => _CoverSearchSheetState();
}

class _CoverSearchSheetState extends State<_CoverSearchSheet> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialQuery,
  );
  bool _searching = false;
  bool _downloading = false;
  List<CoverSearchResult> _results = const [];
  String? _error;

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
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _controller.text.trim();
    if (query.isEmpty || _searching) return;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
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
            ),
      ].where((item) => item.url.isNotEmpty).toList();
      if (!mounted) return;
      setState(() {
        _results = results;
        _searching = false;
        if (results.isEmpty) _error = '未找到相关封面，换个关键词试试';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _results = const [];
        _error = '搜索失败：$e';
      });
    }
  }

  /// 选中封面：预取字节成功才回传 URL，避免写回 tag 时才发现下载失败。
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.72,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
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
              const Divider(height: 1),
              Expanded(
                child: _buildBody(scheme),
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
    if (_searching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
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
          '输入关键词搜索专辑封面',
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
        childAspectRatio: 0.82,
      ),
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final result = _results[index];
        return InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => _pick(result),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ClipRRect(
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
                              child: CircularProgressIndicator(strokeWidth: 2),
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
              ),
              const SizedBox(height: 4),
              Text(
                result.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
              Text(
                result.artist,
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
