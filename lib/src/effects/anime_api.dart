// anime_api.dart — anime 音效开放平台客户端（open.anime.bzxhkj.com）
//
// 接入约定（官方 docs.php v1）：
// - GET /api/?route=open_effect_list，双请求头 X-Anime-Key / X-Anime-App
// - 响应 {code:0, msg, data:{official:[...], user:[...]}}；限频 120 次/分钟
// - 音效 params 为原始调音 JSON（schema v1），直传 Rust 侧官方 animefx.c
//   引擎，不做字段改写
//
// 缓存策略：列表成功拉取后落 SharedPreferences；TTL 内直接用缓存，过期
// 或强制刷新走网络；网络失败回退过期缓存（fromCache=true），无缓存才抛错。

import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_http.dart';

const _animeApiBase = 'https://open.anime.bzxhkj.com/api/';
const _animeAppId = '6';
const _animeAppKey = 'oan_d2e24b3389226f75cb046c6d6caba638ce32ae13';

const _cacheKey = 'anime.fx.list.v1';
const _cacheTimeKey = 'anime.fx.list.time.v1';
const _cacheTtl = Duration(hours: 6);

class AnimeEffect {
  final int id;
  final String name;
  final String intro;
  /// 原始调音参数 JSON（schema v1），直传 animefx 引擎。
  final String params;
  final bool official;
  final String? author;

  const AnimeEffect({
    required this.id,
    required this.name,
    required this.intro,
    required this.params,
    required this.official,
    required this.author,
  });

  factory AnimeEffect.fromJson(Map<String, dynamic> j, {required bool official}) {
    return AnimeEffect(
      id: (j['id'] as num?)?.toInt() ?? 0,
      name: (j['name'] as String?) ?? '',
      intro: (j['intro'] as String?) ?? '',
      params: (j['params'] as String?) ?? '',
      official: official,
      author: j['author'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'intro': intro,
        'params': params,
        'official': official,
        if (author != null) 'author': author,
      };
}

class AnimeEffectListResult {
  final List<AnimeEffect> effects;
  /// true = 来自本地缓存（拉取失败回退），UI 可提示数据非实时。
  final bool fromCache;
  const AnimeEffectListResult(this.effects, {required this.fromCache});
}

class AnimeApiException implements Exception {
  final String message;
  AnimeApiException(this.message);
  @override
  String toString() => message;
}

List<AnimeEffect> _parseEffects(dynamic raw) {
  final list = <AnimeEffect>[];
  if (raw is! List) return list;
  for (final item in raw) {
    if (item is! Map<String, dynamic>) continue;
    // 仅收上架音效（status==1）；params 为空（未配置调音）同样跳过。
    final status = (item['status'] as num?)?.toInt() ?? 1;
    if (status != 1) continue;
    final fx = AnimeEffect.fromJson(item, official: false);
    if (fx.params.isEmpty || fx.id == 0) continue;
    list.add(fx);
  }
  return list;
}

Future<AnimeEffectListResult> fetchAnimeEffects({bool force = false}) async {
  final prefs = await SharedPreferences.getInstance();
  final cachedRaw = prefs.getString(_cacheKey);
  final cachedAtMs = prefs.getInt(_cacheTimeKey) ?? 0;
  final cacheAge = DateTime.now().millisecondsSinceEpoch - cachedAtMs;
  final cacheFresh = cachedRaw != null && cacheAge < _cacheTtl.inMilliseconds;

  if (!force && cacheFresh) {
    try {
      return AnimeEffectListResult(_decodeCached(cachedRaw), fromCache: false);
    } catch (_) {
      // 缓存损坏则走网络重拉。
    }
  }

  try {
    final uri = Uri.parse('$_animeApiBase?route=open_effect_list');
    final resp = await appGet(uri, headers: {
      'X-Anime-Key': _animeAppKey,
      'X-Anime-App': _animeAppId,
    }).timeout(const Duration(seconds: 15));
    final body = await utf8.decodeStream(resp);
    if (resp.statusCode != 200) {
      throw AnimeApiException('HTTP ${resp.statusCode}：${body.length > 200 ? '${body.substring(0, 200)}…' : body}');
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw AnimeApiException('响应格式异常：非 JSON 对象');
    }
    final code = (decoded['code'] as num?)?.toInt() ?? -1;
    final msg = (decoded['msg'] as String?) ?? '';
    if (code != 0) {
      // 按约定透出业务 code 与详情，便于定位（鉴权失败/限频等）。
      throw AnimeApiException('接口业务错误 code=$code：$msg');
    }
    final data = decoded['data'];
    if (data is! Map<String, dynamic>) {
      throw AnimeApiException('响应缺少 data 对象');
    }
    final effects = [
      ..._parseEffects(data['official']).map((fx) => AnimeEffect(
            id: fx.id,
            name: fx.name,
            intro: fx.intro,
            params: fx.params,
            official: true,
            author: fx.author,
          )),
      ..._parseEffects(data['user']),
    ];
    final result = AnimeEffectListResult(effects, fromCache: false);
    // 拉取成功后写缓存（失败不影响结果）。
    try {
      await prefs.setString(_cacheKey, jsonEncode(effects.map((e) => e.toJson()).toList()));
      await prefs.setInt(_cacheTimeKey, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
    return result;
  } on AnimeApiException {
    rethrow;
  } catch (e) {
    // 网络失败：回退过期缓存，保证音效广场离线可用。
    if (cachedRaw != null) {
      try {
        return AnimeEffectListResult(_decodeCached(cachedRaw), fromCache: true);
      } catch (_) {}
    }
    throw AnimeApiException('音效列表拉取失败：$e');
  }
}

List<AnimeEffect> _decodeCached(String raw) {
  final list = (jsonDecode(raw) as List? ?? const [])
      .map((e) => AnimeEffect.fromJson(e as Map<String, dynamic>, official: e['official'] == true))
      .toList();
  return list;
}
