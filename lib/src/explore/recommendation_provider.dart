import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../favorites/favorites_provider.dart';
import '../library/library_provider.dart';
import '../playlists/playlists_provider.dart';
import '../plugins/plugin_runtime.dart';
import '../recent/recent_provider.dart';

const _maxRecommendationCount = 150;

/// 首页进入后在后台预热探索页数据。Provider 本身会缓存结果，用户真正打开
/// 探索页时通常已经有可直接展示的内容，不再把插件网络请求放在页面首帧。
void preloadExploreData(WidgetRef ref) {
  unawaited(
    ref
        .read(exploreRecommendationsProvider.future)
        .catchError((_) => const <Song>[]),
  );
  unawaited(
    ref
        .read(explorePlaylistRecommendationsProvider.future)
        .catchError((_) => const <RecommendedPlaylist>[]),
  );
  unawaited(
    ref
        .read(exploreHotChartsProvider.future)
        .catchError((_) => const <RecommendedPlaylist>[]),
  );
}

/// 本地偏好生成的网络歌曲推荐。
///
/// 只读取本地播放/收藏/歌单数据，搜索候选时才把歌手或专辑关键词交给
/// 已启用插件；不会把完整播放记录上传到服务端。
final exploreRecommendationsProvider = FutureProvider<List<Song>>((ref) async {
  final refreshTimer = Timer(const Duration(minutes: 30), ref.invalidateSelf);
  ref.onDispose(refreshTimer.cancel);

  final library = ref.read(libraryProvider).songs;
  final localByPath = {for (final song in library) song.path: song};
  final favorites = ref.read(favoritesProvider.notifier);
  await favorites.ready;
  final playlists = ref.read(playlistsProvider.notifier);
  await playlists.ready;

  final seeds = <Song>[];
  final seenSeedPaths = <String>{};
  final seenSeedKeys = <String>{};
  void addSeed(Song? song) {
    if (song == null || song.title.trim().isEmpty) return;
    // 同一首网络歌曲可能同时出现在最近播放、收藏和多个歌单中。
    // 只按 path 去重会让它重复提高某位歌手/专辑的权重，导致推荐被一两首歌带偏。
    final tasteKey = _songTasteKey(song.title, song.artist);
    if (tasteKey.isEmpty || !seenSeedKeys.add(tasteKey)) return;
    if (seenSeedPaths.add(song.path)) seeds.add(song);
  }

  // 最近播放体现近期偏好，收藏和歌单体现长期偏好。
  try {
    final recent = await ref.read(recentSongsProvider.future);
    for (final entry in recent.take(20)) {
      addSeed(entry.song);
    }
  } catch (_) {
    // 最近播放读取失败时仍可使用收藏和歌单生成推荐。
  }
  for (final path in favorites.paths) {
    addSeed(favorites.snapshotFor(path)?.toSong() ?? localByPath[path]);
  }
  for (final playlist in playlists.items) {
    for (final path in playlist.songPaths) {
      addSeed(playlist.songSnapshots[path]?.toSong() ?? localByPath[path]);
      if (seeds.length >= 80) break;
    }
    if (seeds.length >= 80) break;
  }
  if (seeds.isEmpty) {
    // 没有任何本地偏好数据时，直接展示插件热门榜单歌曲，
    // 避免新用户在“猜你想听”里只能看到空白。
    final plugins = await ref.read(enabledMusicPluginsProvider.future);
    if (plugins.isEmpty) return const [];
    final runtime = ref.read(pluginRuntimeProvider);
    return (await _loadHotChartSongs(plugins, runtime, const {}))
        .take(_maxRecommendationCount)
        .toList();
  }

  final artistWeights = <String, _TasteTerm>{};
  final albumWeights = <String, _TasteTerm>{};
  final genreWeights = <String, _TasteTerm>{};
  for (var index = 0; index < seeds.length; index++) {
    final song = seeds[index];
    final weight = index < 10
        ? 4
        : index < 30
        ? 2
        : 1;
    if (_isUnknownArtist(song.artist)) {
      // 这类歌曲的作者、专辑和标签往往是插件填充的占位/脏数据，
      // 只保留歌名作为检索线索，避免把污染的信息带进偏好模型。
      continue;
    }
    _addTasteTerm(artistWeights, song.artist, weight);
    _addTasteTerm(albumWeights, song.album, weight);
    for (final genre in _extractGenres(song.pluginData)) {
      _addTasteTerm(genreWeights, genre, weight);
    }
  }
  // 本地歌曲通常没有统一的曲风字段，歌单名称是很有价值的风格线索，
  // 例如“华语流行”“摇滚精选”等，将其作为低权重风格关键词参与搜索。
  for (final playlist in playlists.items) {
    if (!_isGenericPlaylistName(playlist.name)) {
      _addTasteTerm(genreWeights, playlist.name, 2);
    }
  }
  final rankedArtists = artistWeights.values.toList()
    ..sort((a, b) => b.weight.compareTo(a.weight));
  final rankedAlbums = albumWeights.values.toList()
    ..sort((a, b) => b.weight.compareTo(a.weight));
  final rankedGenres = genreWeights.values.toList()
    ..sort((a, b) => b.weight.compareTo(a.weight));
  // 优先取多个不同歌手和曲风，而不是只搜索权重最高的一个歌手。
  // 专辑只作为不足时的补充，避免推荐结果再次集中到同一张专辑。
  final queryList = <String>[];
  final queryKeys = <String>{};
  final titleQueryKeys = <String>{};
  void addQuery(String value) {
    final text = value.trim();
    final key = _tasteText(text);
    if (text.length < 2 || key.isEmpty || !queryKeys.add(key)) return;
    queryList.add(text);
  }

  for (final term in rankedArtists.take(3)) {
    addQuery(term.text);
  }
  for (final term in rankedGenres.take(3)) {
    addQuery(term.text);
  }
  // 歌手缺失或被插件写成“未知歌手”时，不把这个占位文本当作歌手，
  // 只使用歌曲名作为偏好线索，避免未知歌手污染整批推荐。
  for (final song
      in seeds.where((song) => _isUnknownArtist(song.artist)).take(2)) {
    addQuery(song.title);
    titleQueryKeys.add(_tasteText(song.title));
  }
  if (queryList.length < 6) {
    for (final term in rankedAlbums.take(2)) {
      addQuery(term.text);
      if (queryList.length >= 6) break;
    }
  }
  if (queryList.isEmpty) return const [];

  final plugins = await ref.read(enabledMusicPluginsProvider.future);
  if (plugins.isEmpty) return const [];
  final runtime = ref.read(pluginRuntimeProvider);
  final pluginNames = {for (final plugin in plugins) plugin.id: plugin.name};
  final seedKeys = {
    for (final song in seeds) _songTasteKey(song.title, song.artist),
  };
  final ranked = <String, _RecommendedSong>{};
  final tasks = <Future<void>>[];
  // 每次生成使用一个很小的随机扰动。它只用于分数相近的候选，避免
  // 每次刷新都把同一首种子歌曲固定排在最前面，同时不会破坏偏好匹配。
  final rankingRandom = math.Random();
  // 最多使用四个插件、每个插件查询至多五个偏好关键词，避免安装了大量插件
  // 时一次性创建过多 JS 隔离运行时；请求本身在后台执行，不阻塞首帧。
  for (final plugin in plugins.take(3)) {
    for (final query in queryList.take(6)) {
      tasks.add(() async {
        try {
          // 插件接口偶尔会因为源站无响应拖住整个推荐页；单次请求超时
          // 后继续使用其他插件的结果，避免用户一直看到转圈。
          final songs = await runtime
              .search(plugin, query)
              .timeout(const Duration(seconds: 8));
          final filterMissingCovers = _shouldFilterMissingCovers(
            songs.map((song) => song.coverUrl),
          );
          for (final item in songs.take(30)) {
            if (item.title.trim().isEmpty) continue;
            if (filterMissingCovers && item.coverUrl.trim().isEmpty) continue;
            if (_isLikelyNonMusicTitle(item.title)) continue;
            if (_isLikelyIrrelevantContent(
              item.title,
              item.artist,
              item.album,
            )) {
              continue;
            }
            final unknownArtist = _isUnknownArtist(item.artist);
            if (unknownArtist &&
                (!titleQueryKeys.contains(_tasteText(query)) ||
                    !_titleMatchesQuery(item.title, query))) {
              continue;
            }
            final song = Song(
              path: pluginSongPath(plugin, item),
              title: item.title,
              artist: item.artist,
              album: item.album,
              albumKey: item.album,
              duration: (item.durationMs / 1000).round(),
              format: '网络',
              coverUrl: item.coverUrl,
              pluginId: plugin.id,
              pluginData: item.rawData,
              lyricsRaw: _embeddedLyrics(item.rawData),
            );
            final key = _songTasteKey(song.title, song.artist);
            if (key.isEmpty || seedKeys.contains(key)) continue;
            var score = _recommendationScore(
              song,
              artistWeights,
              albumWeights,
              genreWeights,
              query: query,
            );
            score += rankingRandom.nextInt(4);
            // B 站搜索结果经常是“视频标题”而不是规范曲名，例如带有
            // 方括号、UP 主说明、现场/翻唱等后缀。保留这些结果作为兜底，
            // 但在有其他插件结果时降低其排序，避免它们占满推荐列表。
            if (_isBilibiliPlugin(plugin)) {
              score -= _videoTitlePenalty(item.title);
            }
            final previous = ranked[key];
            if (previous == null ||
                score > previous.score ||
                (score == previous.score &&
                    _isBilibiliPluginId(previous.song.pluginId, pluginNames) &&
                    !_isBilibiliPlugin(plugin))) {
              ranked[key] = _RecommendedSong(song: song, score: score);
            }
          }
        } catch (_) {
          // 单个插件失败不影响其他插件的推荐。
        }
      }());
    }
  }
  await Future.wait(tasks);
  // 先按插件轮换，再按歌手轮换。这样安装了多个音源时每个音源都有
  // 展示机会，不会因为某个插件返回量大而垄断推荐结果。
  final groups = <String, List<_RecommendedSong>>{};
  for (final item in ranked.values) {
    final pluginKey = item.song.pluginId?.trim() ?? '';
    if (pluginKey.isEmpty) continue;
    groups.putIfAbsent(pluginKey, () => []).add(item);
  }
  for (final group in groups.values) {
    group.sort((a, b) => b.score.compareTo(a.score));
  }
  final groupList = groups.entries.toList()
    ..sort((a, b) => b.value.first.score.compareTo(a.value.first.score));
  if (groupList.isEmpty) return const [];
  final result = <Song>[];
  final pluginTarget = (_maxRecommendationCount / groupList.length).ceil();
  final pluginCounts = <String, int>{};
  final artistCounts = <String, int>{};
  final titleCounts = <String, int>{};
  final selectedKeys = <String>{};
  // 同名歌曲可能来自不同插件或作者，最多保留两个代表项，避免推荐列表
  // 被同一个歌名刷屏，同时保留少量不同版本供用户选择。
  const titleLimit = 2;
  // B 站仍可参与推荐，但在存在其他插件时最多占两首，且优先选择规范标题。
  final hasAlternativePlugin = groupList.any(
    (entry) => !_isBilibiliPluginId(entry.key, pluginNames),
  );
  final pluginLimits = {
    for (final entry in groupList)
      entry.key:
          _isBilibiliPluginId(entry.key, pluginNames) && hasAlternativePlugin
          ? math.min(pluginTarget, 2)
          : pluginTarget,
  };

  for (
    var round = 0;
    result.length < _maxRecommendationCount && round < _maxRecommendationCount;
    round++
  ) {
    // 一轮内每个歌手只取一次，再进入下一轮。这样即使某个插件返回了
    // 大量同一歌手的歌曲，也不会在列表开头连续出现同一批内容。
    final roundArtists = <String>{};
    for (var groupOffset = 0; groupOffset < groupList.length; groupOffset++) {
      final entry = groupList[(groupOffset + round) % groupList.length];
      final pluginKey = entry.key;
      if ((pluginCounts[pluginKey] ?? 0) >= (pluginLimits[pluginKey] ?? 0)) {
        continue;
      }
      _RecommendedSong? candidate;
      for (final item in entry.value) {
        final key = _songTasteKey(item.song.title, item.song.artist);
        final titleKey = _tasteText(item.song.title);
        final artistKey = _isUnknownArtist(item.song.artist)
            ? '__unknown_artist__'
            : _tasteText(item.song.artist);
        final artistLimit = artistKey == '__unknown_artist__' ? 2 : 3;
        if (!selectedKeys.contains(key) &&
            (titleCounts[titleKey] ?? 0) < titleLimit &&
            (artistCounts[artistKey] ?? 0) < artistLimit &&
            !roundArtists.contains(artistKey)) {
          candidate = item;
          break;
        }
      }
      // 某个插件候选过于集中时，允许它在本轮没有其它歌手可选，
      // 但仍遵守总的歌手上限，避免推荐数量因此不足。
      if (candidate == null) {
        for (final item in entry.value) {
          final key = _songTasteKey(item.song.title, item.song.artist);
          final titleKey = _tasteText(item.song.title);
          final artistKey = _isUnknownArtist(item.song.artist)
              ? '__unknown_artist__'
              : _tasteText(item.song.artist);
          final artistLimit = artistKey == '__unknown_artist__' ? 2 : 3;
          if (!selectedKeys.contains(key) &&
              (titleCounts[titleKey] ?? 0) < titleLimit &&
              (artistCounts[artistKey] ?? 0) < artistLimit) {
            candidate = item;
            break;
          }
        }
      }
      if (candidate == null) continue;
      final key = _songTasteKey(candidate.song.title, candidate.song.artist);
      final titleKey = _tasteText(candidate.song.title);
      final artistKey = _isUnknownArtist(candidate.song.artist)
          ? '__unknown_artist__'
          : _tasteText(candidate.song.artist);
      selectedKeys.add(key);
      roundArtists.add(artistKey);
      pluginCounts[pluginKey] = (pluginCounts[pluginKey] ?? 0) + 1;
      artistCounts[artistKey] = (artistCounts[artistKey] ?? 0) + 1;
      titleCounts[titleKey] = (titleCounts[titleKey] ?? 0) + 1;
      result.add(candidate.song);
      if (result.length >= _maxRecommendationCount) break;
    }
  }

  // 某个插件/歌手候选不足时，用剩余结果补齐，但仍限制同一歌手最多两首。
  if (result.length < _maxRecommendationCount) {
    for (final item
        in ranked.values.toList()..sort((a, b) => b.score.compareTo(a.score))) {
      if (result.length >= _maxRecommendationCount) break;
      final key = _songTasteKey(item.song.title, item.song.artist);
      final titleKey = _tasteText(item.song.title);
      final artistKey = _isUnknownArtist(item.song.artist)
          ? '__unknown_artist__'
          : _tasteText(item.song.artist);
      final artistLimit = artistKey == '__unknown_artist__' ? 2 : 3;
      if (selectedKeys.contains(key) ||
          (titleCounts[titleKey] ?? 0) >= titleLimit ||
          (artistCounts[artistKey] ?? 0) >= artistLimit) {
        continue;
      }
      selectedKeys.add(key);
      artistCounts[artistKey] = (artistCounts[artistKey] ?? 0) + 1;
      titleCounts[titleKey] = (titleCounts[titleKey] ?? 0) + 1;
      result.add(item.song);
    }
  }

  // 适当掺入插件热门榜单歌曲（不依赖个人喜好的大众热门内容）。
  // 思路参考 BakaMusic 推荐歌单：从插件榜单接口拉取当前热门内容，
  // 按大约 4:1 的比例穿插在偏好结果之间，推荐不完全跟随历史喜好。
  if (result.isNotEmpty) {
    final hotSongs = await _loadHotChartSongs(plugins, runtime, seedKeys);
    if (hotSongs.isNotEmpty) {
      final resultKeys = {
        for (final song in result) _songTasteKey(song.title, song.artist),
      };
      final hotQueue = <Song>[];
      for (final song in hotSongs) {
        final key = _songTasteKey(song.title, song.artist);
        if (key.isEmpty || resultKeys.contains(key)) continue;
        resultKeys.add(key);
        hotQueue.add(song);
      }
      if (hotQueue.isNotEmpty) {
        const hotGap = 4;
        var hotIndex = 0;
        final mixed = <Song>[];
        for (final song in result) {
          if (mixed.length >= _maxRecommendationCount) break;
          mixed.add(song);
          if (hotIndex < hotQueue.length && mixed.length % hotGap == 0) {
            mixed.add(hotQueue[hotIndex++]);
          }
        }
        while (hotIndex < hotQueue.length &&
            mixed.length < _maxRecommendationCount) {
          mixed.add(hotQueue[hotIndex++]);
        }
        return mixed;
      }
    }
  }
  return result;
});

/// 探索页的歌单/专辑推荐项。保留插件和原始条目，点击时可直接交给
/// 插件的歌单导入流程，而不是只显示一个无法操作的卡片。
class RecommendedPlaylist {
  const RecommendedPlaylist({required this.plugin, required this.result});

  final EnabledMusicPlugin plugin;
  final PluginCatalogResult result;
}

/// 从已启用插件的热门榜单拉取大众热门歌曲，与个人偏好无关，
/// 用于在“猜你想听”中掺入比较火的内容（参考 BakaMusic 推荐歌单思路）。
Future<List<Song>> _loadHotChartSongs(
  List<EnabledMusicPlugin> plugins,
  PluginRuntimeService runtime,
  Set<String> seedKeys,
) async {
  final result = <Song>[];
  final seenKeys = <String>{};
  final tasks = <Future<void>>[];
  final random = math.Random();
  for (final plugin in plugins.take(3)) {
    // B 站榜单是视频集合，标题多为视频文案，不适合作为热门歌曲来源。
    if (_isBilibiliPlugin(plugin)) continue;
    tasks.add(() async {
      try {
        final charts = await runtime
            .getTopLists(plugin)
            .timeout(const Duration(seconds: 8));
        if (charts.isEmpty) return;
        // 优先选热歌/流行/飙升类榜单，取不到时随机挑一个增加每次刷新的多样性。
        final preferred = charts
            .where(
              (chart) => RegExp(
                '(热歌|热门|流行|飙升|新歌|top|hit|hot)',
                caseSensitive: false,
              ).hasMatch(chart.title),
            )
            .toList();
        final chart = preferred.isNotEmpty
            ? preferred[random.nextInt(preferred.length)]
            : charts[random.nextInt(charts.length)];
        final songs = await runtime
            .getTopListSongs(plugin, chart, limit: 30)
            .timeout(const Duration(seconds: 12));
        final filterMissingCovers = _shouldFilterMissingCovers(
          songs.map((song) => song.coverUrl),
        );
        for (final item in songs) {
          if (item.title.trim().isEmpty) continue;
          if (filterMissingCovers && item.coverUrl.trim().isEmpty) continue;
          if (_isLikelyNonMusicTitle(item.title)) continue;
          if (_isLikelyIrrelevantContent(
            item.title,
            item.artist,
            item.album,
          )) {
            continue;
          }
          final key = _songTasteKey(item.title, item.artist);
          if (key.isEmpty || seedKeys.contains(key) || !seenKeys.add(key)) {
            continue;
          }
          result.add(
            Song(
              path: pluginSongPath(plugin, item),
              title: item.title,
              artist: item.artist,
              album: item.album,
              albumKey: item.album,
              duration: (item.durationMs / 1000).round(),
              format: '网络',
              coverUrl: item.coverUrl,
              pluginId: plugin.id,
              pluginData: item.rawData,
              lyricsRaw: _embeddedLyrics(item.rawData),
            ),
          );
        }
      } catch (_) {
        // 单个插件榜单获取失败不影响其它插件。
      }
    }());
  }
  await Future.wait(tasks);
  result.shuffle();
  return result;
}

final explorePlaylistRecommendationsProvider =
    FutureProvider<List<RecommendedPlaylist>>((ref) async {
      final refreshTimer = Timer(
        const Duration(minutes: 30),
        ref.invalidateSelf,
      );
      ref.onDispose(refreshTimer.cancel);
      final profile = await _loadTasteProfile(ref);
      if (profile == null) return const [];

      final queries = <String>[];
      final seenQueries = <String>{};
      void addQuery(String value) {
        final text = value.trim();
        final key = _tasteText(text);
        if (text.length < 2 || key.isEmpty || !seenQueries.add(key)) return;
        queries.add(text);
      }

      for (final term in profile.rankedArtists.take(3)) {
        addQuery(term.text);
      }
      for (final term in profile.rankedGenres.take(3)) {
        addQuery(term.text);
      }
      for (final song
          in profile.seeds
              .where((song) => _isUnknownArtist(song.artist))
              .take(2)) {
        addQuery(song.title);
      }
      if (queries.isEmpty) return const [];

      final plugins = await ref.read(enabledMusicPluginsProvider.future);
      if (plugins.isEmpty) return const [];
      final runtime = ref.read(pluginRuntimeProvider);
      final ranked = <String, _RecommendedPlaylist>{};
      final tasks = <Future<void>>[];
      final rankingRandom = math.Random();
      for (final plugin in plugins.take(3)) {
        for (final query in queries.take(6)) {
          tasks.add(() async {
            try {
              final results = await runtime
                  .searchPlaylists(plugin, query)
                  .timeout(const Duration(seconds: 8));
              final filterMissingCovers = _shouldFilterMissingCovers(
                results.map((item) => item.coverUrl),
              );
              for (final result in results.take(20)) {
                final title = result.title.trim();
                if (title.isEmpty) continue;
                if (filterMissingCovers && result.coverUrl.trim().isEmpty) {
                  continue;
                }
                // 歌曲数明确为 1 的歌单/专辑不具备推荐价值，直接过滤。
                // 数量字段由不同插件以不同名称返回，未知数量则保留，
                // 避免因插件字段不统一误删正常歌单。
                if (_playlistSongCount(result) == 1) continue;
                // 同名歌单在不同插件中通常是同一份内容，跨插件去重，
                // 避免完整推荐页反复出现同一歌单。
                final key =
                    '${_tasteText(title)}|${_tasteText(result.subtitle)}';
                final score =
                    _playlistRecommendationScore(result, query, profile) +
                    rankingRandom.nextInt(4);
                final previous = ranked[key];
                if (previous == null || score > previous.score) {
                  ranked[key] = _RecommendedPlaylist(
                    plugin: plugin,
                    result: result,
                    score: score,
                    tasteKey: _tasteText(query),
                  );
                }
              }
            } catch (_) {
              // 单个插件不支持歌单搜索时跳过，不影响其他插件。
            }
          }());
        }
      }
      await Future.wait(tasks);
      if (ranked.isEmpty) return const [];

      final groups = <String, List<_RecommendedPlaylist>>{};
      for (final item in ranked.values) {
        groups.putIfAbsent(item.plugin.id, () => []).add(item);
      }
      for (final group in groups.values) {
        group.sort((a, b) => b.score.compareTo(a.score));
      }
      final groupList = groups.entries.toList()
        ..sort((a, b) => b.value.first.score.compareTo(a.value.first.score));
      final target = (_maxRecommendationCount / groupList.length).ceil();
      final limits = {for (final entry in groupList) entry.key: target};
      final counts = <String, int>{};
      final tasteCounts = <String, int>{};
      final result = <RecommendedPlaylist>[];
      for (
        var round = 0;
        result.length < _maxRecommendationCount &&
            round < _maxRecommendationCount;
        round++
      ) {
        final roundTasteKeys = <String>{};
        for (
          var groupOffset = 0;
          groupOffset < groupList.length;
          groupOffset++
        ) {
          final entry = groupList[(groupOffset + round) % groupList.length];
          if ((counts[entry.key] ?? 0) >= (limits[entry.key] ?? 0)) {
            continue;
          }
          _RecommendedPlaylist? item;
          for (final candidate in entry.value) {
            final duplicate = result.any(
              (selected) =>
                  selected.plugin.id == candidate.plugin.id &&
                  selected.result.id == candidate.result.id,
            );
            final tasteKey = candidate.tasteKey;
            if (!duplicate &&
                !roundTasteKeys.contains(tasteKey) &&
                (tasteCounts[tasteKey] ?? 0) < 5) {
              item = candidate;
              break;
            }
          }
          // 插件只返回单一风格歌单时仍然允许补位，但先尝试过均衡候选。
          item ??= entry.value.firstWhere(
            (candidate) => !result.any(
              (selected) =>
                  selected.plugin.id == candidate.plugin.id &&
                  selected.result.id == candidate.result.id,
            ),
            orElse: () => const _RecommendedPlaylist.empty(),
          );
          final selectedItem = item;
          if (selectedItem.isEmpty) continue;
          counts[entry.key] = (counts[entry.key] ?? 0) + 1;
          roundTasteKeys.add(selectedItem.tasteKey);
          tasteCounts[selectedItem.tasteKey] =
              (tasteCounts[selectedItem.tasteKey] ?? 0) + 1;
          result.add(
            RecommendedPlaylist(
              plugin: selectedItem.plugin,
              result: selectedItem.result,
            ),
          );
          if (result.length >= _maxRecommendationCount) break;
        }
      }
      return result;
    });

/// 各已启用 MusicFree 插件提供的热门榜单。榜单条目沿用推荐歌单模型，
/// 点击后可以直接进入榜单详情并播放全部歌曲。
final exploreHotChartsProvider = FutureProvider<List<RecommendedPlaylist>>((
  ref,
) async {
  final refreshTimer = Timer(const Duration(minutes: 30), ref.invalidateSelf);
  ref.onDispose(refreshTimer.cancel);

  final plugins = await ref.read(enabledMusicPluginsProvider.future);
  if (plugins.isEmpty) return const [];
  final runtime = ref.read(pluginRuntimeProvider);
  final result = <RecommendedPlaylist>[];
  final tasks = <Future<void>>[];
  // 每个插件只请求一次榜单接口；每个插件最多展示 8 个榜单，避免某个
  // 插件返回大量分类时挤占其他插件的展示机会。
  for (final plugin in plugins) {
    tasks.add(() async {
      try {
        final charts = await runtime
            .getTopLists(plugin)
            .timeout(const Duration(seconds: 8));
        final filterMissingCovers = _shouldFilterMissingCovers(
          charts.map((item) => item.coverUrl),
        );
        final seen = <String>{};
        for (final chart in charts) {
          if (chart.title.trim().isEmpty) continue;
          if (filterMissingCovers && chart.coverUrl.trim().isEmpty) {
            continue;
          }
          if (_playlistSongCount(chart) == 1) continue;
          final key = '${_tasteText(chart.id)}|${_tasteText(chart.title)}';
          if (!seen.add(key)) continue;
          result.add(RecommendedPlaylist(plugin: plugin, result: chart));
          if (seen.length >= 8) break;
        }
      } catch (_) {
        // 单个插件不支持热门榜单时跳过，不影响其他插件。
      }
    }());
  }
  await Future.wait(tasks);

  // 大多数插件的榜单接口只返回 id/title，不带封面字段，导致榜单卡片
  // 全部显示占位图标。对缺封面的榜单，取榜单内第一首有封面的歌曲
  // 作为榜单封面回填，榜单详情页同样受益。
  final coverTasks = <Future<void>>[];
  for (var index = 0; index < result.length; index++) {
    final entry = result[index];
    if (entry.result.coverUrl.trim().isNotEmpty) continue;
    coverTasks.add(() async {
      try {
        final songs = await runtime
            .getTopListSongs(entry.plugin, entry.result, limit: 5)
            .timeout(const Duration(seconds: 8));
        for (final song in songs) {
          final cover = song.coverUrl.trim();
          if (cover.isEmpty) continue;
          result[index] = RecommendedPlaylist(
            plugin: entry.plugin,
            result: PluginCatalogResult(
              pluginId: entry.result.pluginId,
              id: entry.result.id,
              title: entry.result.title,
              subtitle: entry.result.subtitle,
              coverUrl: cover,
              rawData: entry.result.rawData,
            ),
          );
          break;
        }
      } catch (_) {
        // 封面回填失败不影响榜单展示，保留占位图。
      }
    }());
  }
  if (coverTasks.isNotEmpty) await Future.wait(coverTasks);
  return result;
});

class _TasteProfile {
  const _TasteProfile({
    required this.seeds,
    required this.artistWeights,
    required this.albumWeights,
    required this.genreWeights,
  });

  final List<Song> seeds;
  final Map<String, _TasteTerm> artistWeights;
  final Map<String, _TasteTerm> albumWeights;
  final Map<String, _TasteTerm> genreWeights;

  List<_TasteTerm> get rankedArtists =>
      artistWeights.values.toList()
        ..sort((a, b) => b.weight.compareTo(a.weight));

  List<_TasteTerm> get rankedGenres =>
      genreWeights.values.toList()
        ..sort((a, b) => b.weight.compareTo(a.weight));
}

Future<_TasteProfile?> _loadTasteProfile(Ref ref) async {
  final library = ref.read(libraryProvider).songs;
  final localByPath = {for (final song in library) song.path: song};
  final favorites = ref.read(favoritesProvider.notifier);
  await favorites.ready;
  final playlists = ref.read(playlistsProvider.notifier);
  await playlists.ready;
  final seeds = <Song>[];
  final seen = <String>{};
  void addSeed(Song? song) {
    if (song == null || song.title.trim().isEmpty) return;
    final key = _songTasteKey(song.title, song.artist);
    if (key.isNotEmpty && seen.add(key)) seeds.add(song);
  }

  try {
    final recent = await ref.read(recentSongsProvider.future);
    for (final entry in recent.take(20)) {
      addSeed(entry.song);
    }
  } catch (_) {}
  for (final path in favorites.paths) {
    addSeed(favorites.snapshotFor(path)?.toSong() ?? localByPath[path]);
  }
  for (final playlist in playlists.items) {
    for (final path in playlist.songPaths) {
      addSeed(playlist.songSnapshots[path]?.toSong() ?? localByPath[path]);
      if (seeds.length >= 80) break;
    }
    if (seeds.length >= 80) break;
  }
  if (seeds.isEmpty) return null;

  final artists = <String, _TasteTerm>{};
  final albums = <String, _TasteTerm>{};
  final genres = <String, _TasteTerm>{};
  for (var index = 0; index < seeds.length; index++) {
    final weight = index < 10
        ? 4
        : index < 30
        ? 2
        : 1;
    final song = seeds[index];
    if (_isUnknownArtist(song.artist)) {
      continue;
    }
    _addTasteTerm(artists, song.artist, weight);
    _addTasteTerm(albums, song.album, weight);
    for (final genre in _extractGenres(song.pluginData)) {
      _addTasteTerm(genres, genre, weight);
    }
  }
  for (final playlist in playlists.items) {
    if (!_isGenericPlaylistName(playlist.name)) {
      _addTasteTerm(genres, playlist.name, 2);
    }
  }
  return _TasteProfile(
    seeds: seeds,
    artistWeights: artists,
    albumWeights: albums,
    genreWeights: genres,
  );
}

int _playlistRecommendationScore(
  PluginCatalogResult result,
  String query,
  _TasteProfile profile,
) {
  final text = _tasteText('${result.title} ${result.subtitle}');
  final queryKey = _tasteText(query);
  var score = text.contains(queryKey) ? 40 : 5;
  for (final term in profile.rankedArtists.take(6)) {
    if (text.contains(_tasteText(term.text))) score += term.weight * 18;
  }
  for (final term in profile.rankedGenres.take(6)) {
    if (text.contains(_tasteText(term.text))) score += term.weight * 12;
  }
  return score;
}

class _RecommendedPlaylist {
  const _RecommendedPlaylist({
    required this.plugin,
    required this.result,
    required this.score,
    required this.tasteKey,
  });

  const _RecommendedPlaylist.empty()
    : plugin = const EnabledMusicPlugin(id: '', name: '', path: ''),
      result = const PluginCatalogResult(
        pluginId: '',
        id: '',
        title: '',
        subtitle: '',
        coverUrl: '',
        rawData: {},
      ),
      score = -1,
      tasteKey = '';

  final EnabledMusicPlugin plugin;
  final PluginCatalogResult result;
  final int score;
  // 触发该歌单搜索的偏好词（歌手或曲风），用于跨查询均衡展示。
  final String tasteKey;
  bool get isEmpty => score < 0;
}

class _TasteTerm {
  const _TasteTerm(this.text, this.weight);
  final String text;
  final int weight;
}

void _addTasteTerm(Map<String, _TasteTerm> target, String raw, int weight) {
  final text = raw.trim();
  if (text.length < 2) return;
  final key = text.toLowerCase();
  final old = target[key];
  // 同一歌手/曲风被多首歌重复命中时采用上限，避免一个大歌单或
  // 连续播放同一位歌手把偏好模型完全污染。
  target[key] = _TasteTerm(text, math.min(10, (old?.weight ?? 0) + weight));
}

int _recommendationScore(
  Song song,
  Map<String, _TasteTerm> artists,
  Map<String, _TasteTerm> albums,
  Map<String, _TasteTerm> genres, {
  String? query,
}) {
  final unknownArtist = _isUnknownArtist(song.artist);
  final artist = unknownArtist
      ? null
      : artists[song.artist.trim().toLowerCase()];
  final album = unknownArtist ? null : albums[song.album.trim().toLowerCase()];
  final genreScore = unknownArtist
      ? 0
      : _extractGenres(song.pluginData).fold<int>(
          0,
          (sum, genre) => sum + (genres[genre.toLowerCase()]?.weight ?? 0),
        );
  // 曲风作为跨歌手的核心匹配项，歌手仍保持最高权重但不再一票垄断。
  // 歌手是重要线索，但不能压过曲风和其它偏好，否则最近一首歌的歌手
  // 会把整个推荐列表“吸”过去。配合最终的歌手轮换配额，保证结果更均衡。
  var score =
      (artist?.weight ?? 0) * 42 +
      genreScore * 35 +
      (album?.weight ?? 0) * 14 +
      1;
  final queryKey = _tasteText(query ?? '');
  if (queryKey.isNotEmpty && _tasteText(song.title).contains(queryKey)) {
    score += 45;
  }
  // 未知歌手不提供可靠的作者信息，只保留歌曲名/曲风带来的匹配分，
  // 并轻微降权，避免这类脏数据占满推荐列表。
  if (unknownArtist) score -= 18;
  return score;
}

bool _titleMatchesQuery(String title, String query) {
  final titleKey = _tasteText(title);
  final queryKey = _tasteText(query);
  if (titleKey.length < 2 || queryKey.length < 2) return false;
  return titleKey.contains(queryKey) || queryKey.contains(titleKey);
}

bool _isLikelyNonMusicTitle(String value) => RegExp(
  r'(放屁|屁声|fart|burp|呕吐|呕吐声|咳嗽|咳嗽声|喷嚏|打鼾|打呼噜|snore)',
  caseSensitive: false,
).hasMatch(value);

/// 与用户听歌偏好无关、也非大众流行音乐的内容，例如婴幼儿儿歌、
/// 胎教早教、佛经禅修等。这类条目经常混在插件的搜索和榜单结果里，
/// 无论偏好匹配还是热门掺入都需要过滤。
bool _isLikelyIrrelevantContent(String title, String artist, String album) {
  final text = '$title $artist $album';
  return RegExp(
    r'(儿歌|童谣|童歌|幼儿|婴幼|早教|胎教|摇篮曲|亲宝|贝瓦|咕力|佛经|佛曲|佛乐|佛音|佛号|'
    r'诵经|念经|读经|经文|经咒|大悲咒|往生咒|楞严咒|金刚经|地藏经|阿弥陀|观音|禅修|禅乐|'
    r'禅音|冥想|asmr|白噪音|哄睡|睡前故事|童话故事|国学|三字经|弟子规|百家姓|千字文|'
    r'评书|相声|小品|广播剧|有声书|nursery\s*rhymes|kids\s*songs|buddhist\s*chant|sutra|mantra)',
    caseSensitive: false,
  ).hasMatch(text);
}

bool _isUnknownArtist(String value) {
  final normalized = _tasteText(value);
  return normalized.isEmpty ||
      const {
        '未知',
        '未知歌手',
        '未知艺术家',
        '歌手未知',
        'unknown',
        'unknownartist',
        'unknownsinger',
        'anonymous',
        'variousartists',
        'various',
        '佚名',
        '不详',
        '无名',
        'null',
        'none',
        'na',
        'n/a',
      }.contains(normalized);
}

List<String> _extractGenres(Map<String, dynamic>? raw) {
  if (raw == null || raw.isEmpty) return const [];
  const keys = [
    'genre',
    'genres',
    'style',
    'styles',
    'musicStyle',
    'music_style',
    'category',
    'tags',
  ];
  final values = <String>[];
  for (final key in keys) {
    final value = raw[key];
    if (value is String) {
      values.addAll(value.split(RegExp(r'[,，、/|]')));
    } else if (value is Iterable) {
      values.addAll(value.map((item) => item.toString()));
    }
  }
  return values
      .map((value) => value.trim())
      .where((value) => value.length >= 2 && value.length <= 24)
      .toSet()
      .toList();
}

bool _isGenericPlaylistName(String value) {
  final normalized = _tasteText(value);
  return const {
    '我喜欢',
    '我的收藏',
    '收藏',
    '喜欢',
    '我喜欢的音乐',
  }.map(_tasteText).contains(normalized);
}

int? _playlistSongCount(PluginCatalogResult result) {
  int? parseCount(dynamic value) {
    if (value is num && value.isFinite) return value.toInt();
    if (value is String) {
      final match = RegExp(r'\d+').firstMatch(value);
      if (match != null) return int.tryParse(match.group(0)!);
    }
    if (value is Map) {
      for (final key in const ['value', 'count', 'total', 'num']) {
        final nested = parseCount(value[key]);
        if (nested != null) return nested;
      }
    }
    return null;
  }

  int? findInMap(Map<dynamic, dynamic> raw, [int depth = 0]) {
    if (depth > 2) return null;
    final hasPlaylistIdentity = raw.keys.any(
      (key) => const {
        'id',
        'playlistId',
        'sheetId',
        'albumId',
        'album_id',
      }.contains(key.toString()),
    );
    for (final entry in raw.entries) {
      final key = entry.key.toString().toLowerCase().replaceAll(
        RegExp(r'[^a-z0-9]'),
        '',
      );
      if ((key.contains('song') ||
                  key.contains('track') ||
                  key.contains('music') ||
                  // Bilibili 歌单通常把曲目称为视频/稿件，不会提供
                  // songCount；之前因此无法过滤只有一个视频的歌单。
                  key.contains('video') ||
                  key.contains('archive')) &&
              (key.contains('count') ||
                  key.contains('num') ||
                  key.contains('total') ||
                  key.contains('length')) ||
          (key == 'count' && hasPlaylistIdentity)) {
        final count = parseCount(entry.value);
        if (count != null) return count;
      }
    }
    // 部分 B 站插件直接返回 videos: 1 / videoCount: 1，字段名本身
    // 不含 count/num，单靠上面的通用规则会漏掉这种情况。
    for (final key in const [
      'videos',
      'videoCount',
      'video_count',
      'videoNum',
      'video_num',
      'totalVideos',
      'total_videos',
      'numVideos',
      'num_videos',
      'archivesCount',
      'archives_count',
    ]) {
      if (!raw.containsKey(key)) continue;
      final count = parseCount(raw[key]);
      if (count != null) return count;
    }
    for (final key in const [
      'songs',
      'tracks',
      'songList',
      'musicList',
      'music',
      'song',
      'videos',
      'videoList',
      'video_list',
      'archives',
    ]) {
      final value = raw[key];
      if (value is Iterable) return value.length;
    }
    for (final key in const [
      'data',
      'list',
      'items',
      'result',
      'info',
      'playlist',
      'sheet',
    ]) {
      final value = raw[key];
      if (value is Iterable && value.isNotEmpty) {
        final maps = value.whereType<Map>().toList(growable: false);
        // 部分插件把歌单曲目直接放在 data/list 中，而不是提供数量字段。
        if (maps.length == value.length &&
            maps.every(
              (item) =>
                  item.containsKey('title') ||
                  item.containsKey('name') ||
                  item.containsKey('songname') ||
                  item.containsKey('musicName') ||
                  item.containsKey('url'),
            )) {
          return value.length;
        }
      }
      if (value is Map) {
        final count = findInMap(value, depth + 1);
        if (count != null) return count;
      }
    }
    return null;
  }

  return findInMap(result.rawData);
}

bool _shouldFilterMissingCovers(Iterable<String> covers) {
  var total = 0;
  var missing = 0;
  for (final cover in covers) {
    total++;
    if (cover.trim().isEmpty) missing++;
  }
  // 只有无封面比例不超过一半时过滤；超过一半说明插件整体未提供封面，
  // 此时保留结果，避免把整个插件的推荐清空。
  return total > 0 && missing * 2 <= total;
}

String _songTasteKey(String title, String artist) =>
    '${_tasteText(title)}|${_tasteText(artist)}';

String _tasteText(String value) => value.toLowerCase().replaceAll(
  RegExp(r'[^a-z0-9\u3400-\u9fff]+', unicode: true),
  '',
);

String? _embeddedLyrics(Map<String, dynamic> raw) {
  for (final key in const [
    'yrc',
    'qrc',
    'eslrc',
    'lxlyric',
    'lyric',
    'rawLrc',
    'lrc',
    'lyrics',
  ]) {
    final value = raw[key];
    if (value is String && value.trim().isNotEmpty) return value;
  }
  return null;
}

class _RecommendedSong {
  const _RecommendedSong({required this.song, required this.score});
  final Song song;
  final int score;
}

bool _isBilibiliPlugin(EnabledMusicPlugin plugin) =>
    _isBilibiliPluginId(plugin.id, {plugin.id: plugin.name});

bool _isBilibiliPluginId(String? pluginId, Map<String, String> pluginNames) {
  final id = pluginId?.trim().toLowerCase() ?? '';
  final name = pluginNames[pluginId]?.trim().toLowerCase() ?? '';
  final value = '$id $name';
  return value.contains('bilibili') ||
      value.contains('哔哩') ||
      value.contains('b站');
}

int _videoTitlePenalty(String title) {
  final value = title.trim();
  if (value.isEmpty) return 0;
  var penalty = 0;
  if (RegExp(r'[\[\]【】|｜]').hasMatch(value)) penalty += 55;
  if (RegExp(
    r'(up主|官方|现场|翻唱|纯音乐|高音质|动态歌词|完整版|mv|music\s*video|live|cover)',
    caseSensitive: false,
  ).hasMatch(value)) {
    penalty += 35;
  }
  return penalty;
}
