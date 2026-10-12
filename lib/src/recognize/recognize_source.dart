import '../plugins/plugin_runtime.dart';

/// 识曲歌曲来源推断（显示层兜底，不改变播放语义）。
///
/// 修复背景：旧版本持久化的识曲歌曲（会话恢复、最近播放、收藏、
/// 歌单快照、播放回退关联等）pluginId 为空，且没有播放回退写入的
/// `_recognizedPluginFallback` 缓存。详情页因此显示“本地音乐”、
/// 歌手区不显示“作品”入口、列表不显插件名标签。
///
/// 这类歌曲具备两个可推断信号：路径形如 `lx://<source>/<id>`
/// （识曲映射恒为酷狗 `kg`），且 `pluginData['lx']['source']` 记录
/// 音源代号。据此可在已启用的洛雪插件中还原来源插件，用于 UI 展示；
/// 播放路径不受影响（仍走识曲回退链，解析成功后由
/// `_cacheRecognizedPluginSource` 回写持久化数据）。

/// 从识曲/洛雪歌单虚拟路径提取音源代号（`lx://<source>/<id>`）。
/// 非 `lx://` 路径返回 null。
String? lxSourceFromPath(String path) {
  const prefix = 'lx://';
  if (!path.startsWith(prefix)) return null;
  final rest = path.substring(prefix.length);
  final slash = rest.indexOf('/');
  if (slash <= 0) return null;
  return rest.substring(0, slash);
}

/// 从插件元数据的洛雪条目提取音源代号（识曲映射恒为 `kg`）。
String? lxSourceFromPluginData(Map<String, dynamic>? pluginData) {
  final lx = pluginData?['lx'];
  if (lx is! Map) return null;
  final source = lx['source']?.toString().trim() ?? '';
  return source.isEmpty ? null : source;
}

/// 按音源代号挑选洛雪插件：优先 `lxSources` 命中的插件，回退第一个
/// 洛雪插件（与识曲映射 `_lxPluginForSource`、洛雪歌单导入同一策略）。
String? lxPluginIdForSource(
  List<EnabledMusicPlugin> lxPlugins,
  String source,
) {
  if (lxPlugins.isEmpty) return null;
  for (final plugin in lxPlugins) {
    if (plugin.lxSources.isNotEmpty && plugin.lxSources.contains(source)) {
      return plugin.id;
    }
  }
  return lxPlugins.first.id;
}

/// 为存量识曲/洛雪歌曲推断来源插件 ID（显示层兜底）。
///
/// 仅当能从路径或 `pluginData['lx']` 确认音源代号时才返回非空，
/// 避免普通本地/其它插件歌曲被误标。读不到时返回 null，调用方继续
/// 显示“本地音乐”或不显示来源标签。
String? inferRecognizedLxPluginId({
  required String path,
  Map<String, dynamic>? pluginData,
  required List<EnabledMusicPlugin> lxPlugins,
}) {
  if (lxPlugins.isEmpty) return null;
  final source = lxSourceFromPluginData(pluginData) ?? lxSourceFromPath(path);
  if (source == null || source.isEmpty) return null;
  return lxPluginIdForSource(lxPlugins, source);
}
