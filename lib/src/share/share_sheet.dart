// 歌曲分享弹层：分享到 QQ 好友 / QQ 空间（网页卡片）与复制分享链接。
//
// 分享以网页卡片落地页深链进行：接收方打开链接拉起 App 并播放歌曲。
// 打开菜单不阻塞，点击对应目标时才现场生成分享链接与封面缩略图。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;

import '../auth/auth_provider.dart';
import '../player/player_provider.dart';
import '../rust/api.dart';
import '../widgets/cover_image.dart';
import '../widgets/top_notice.dart';
import 'qq_share_service.dart';
import 'share_service.dart';

/// 弹出歌曲分享菜单（居中弹窗，参考弦予音乐弹窗式菜单设计）：
/// QQ 好友 / QQ 空间 / 复制链接。
///
/// [extraActions] 允许调用方追加菜单项（如播放页的「保存为分享图片」），
/// 在 QQ 分享项之后、复制链接之前插入；建议使用 [shareMenuRow] 构建，
/// 与弹窗内其余条目样式保持一致。
Future<void> showSongShareSheet(
  BuildContext context, {
  required WidgetRef ref,
  required QueueItem song,
  List<Widget> extraActions = const [],
}) async {
  await showDialog<void>(
    context: context,
    useRootNavigator: true,
    builder: (dialogContext) => Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '分享',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(dialogContext).colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              shareMenuRow(
                dialogContext,
                leading: _qqBadge('assets/share_qq.png', fit: BoxFit.contain),
                title: '分享到 QQ 好友',
                subtitle: '以音乐卡片形式发送',
                onTap: () {
                  Navigator.pop(dialogContext);
                  _shareViaQQ(context, ref, song, scene: _kSceneQQ);
                },
              ),
              shareMenuRow(
                dialogContext,
                leading: _qqBadge('assets/share_qzone.jpg'),
                title: '分享到 QQ 空间',
                subtitle: 'QQ 空间支持网页分享，不支持音乐卡片',
                onTap: () {
                  Navigator.pop(dialogContext);
                  _shareViaQQ(context, ref, song, scene: _kSceneQZone);
                },
              ),
              ...extraActions,
              shareMenuRow(
                dialogContext,
                leading: const Icon(Icons.link_outlined),
                title: '复制分享链接',
                onTap: () {
                  Navigator.pop(dialogContext);
                  _copyLink(context, ref, song);
                },
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// 分享弹窗的条目行：图标 + 标题（可带副标题说明）+ 右箭头，
/// 与播放页更多菜单弹窗的行样式一致，供 [showSongShareSheet] 与
/// 调用方的 [showSongShareSheet.extraActions] 统一外观。
Widget shareMenuRow(
  BuildContext context, {
  required Widget leading,
  required String title,
  String? subtitle,
  VoidCallback? onTap,
}) {
  final scheme = Theme.of(context).colorScheme;
  return InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(10),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
      child: Row(
        children: [
          SizedBox(width: 20, height: 20, child: Center(child: leading)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
                if (subtitle?.isNotEmpty == true)
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: scheme.outline),
                  ),
              ],
            ),
          ),
          Icon(
            Icons.chevron_right_rounded,
            size: 20,
            color: scheme.outline,
          ),
        ],
      ),
    ),
  );
}

// tencent_kit 的场景常量（避免 UI 层直接依赖插件）。
const int _kSceneQQ = 0; // TencentScene.kScene_QQ
const int _kSceneQZone = 1; // TencentScene.kScene_QZone

/// QQ/QQ空间品牌徽章图标：白边圆形裁切，明暗弹窗下都清晰。
/// [fit] 控制图标填充方式：透明去底的品牌 logo（如 QQ 企鹅）用 contain 保留整体，
/// 满幅方形图标（如 QQ 空间）用默认 cover 裁满圆圈。
Widget _qqBadge(String asset, {BoxFit fit = BoxFit.cover}) => Container(
      width: 34,
      height: 34,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white,
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.asset(asset, width: 34, height: 34, fit: fit),
    );

void _notice(BuildContext context, String message, XyNoticeType type) {
  if (!context.mounted) return;
  XyNotice.show(context, message: message, type: type);
}

/// 获取（必要时生成）分享链接；失败返回空串。
Future<String> _ensureUrl(WidgetRef ref, QueueItem song) async {
  final share = ref.read(shareServiceProvider);
  final cached = share.cached(song);
  if (cached != null && cached.isNotEmpty) return cached;
  try {
    return await share.create(song);
  } catch (_) {
    return '';
  }
}

/// 分享文案：第一行「用户名邀请你去 XY Music 听《歌名》」，第二行分享链接。
/// 未登录时第一行省略用户名。
String _buildShareText(WidgetRef ref, QueueItem song, String url) {
  final user = ref.read(authProvider).user;
  final nickname = (user?.nickname ?? '').trim();
  final name = nickname.isNotEmpty ? nickname : (user?.username ?? '').trim();
  final firstLine = name.isEmpty
      ? '邀请你去 XY Music 听《${song.title}》'
      : '$name邀请你去 XY Music 听《${song.title}》';
  return '$firstLine\n$url';
}

/// 生成并复制分享链接。
Future<void> _copyLink(
    BuildContext context, WidgetRef ref, QueueItem song) async {
  final url = await _ensureUrl(ref, song);
  if (!context.mounted) return;
  if (url.isEmpty) {
    _notice(context, '生成分享链接失败', XyNoticeType.error);
    return;
  }
  await Clipboard.setData(ClipboardData(text: _buildShareText(ref, song, url)));
  if (!context.mounted) return;
  _notice(context, '分享文案已复制', XyNoticeType.success);
}

/// 分享网页卡片到指定 QQ 场景（好友 / 空间）。
Future<void> _shareViaQQ(
  BuildContext context,
  WidgetRef ref,
  QueueItem song, {
  required int scene,
}) async {
  final url = await _ensureUrl(ref, song);
  if (!context.mounted) return;
  if (url.isEmpty) {
    _notice(context, '生成分享链接失败', XyNoticeType.error);
    return;
  }

  final qq = ref.read(qqShareServiceProvider);
  if (!await qq.isQQInstalled()) {
    if (!context.mounted) return;
    await Clipboard.setData(
        ClipboardData(text: _buildShareText(ref, song, url)));
    if (!context.mounted) return;
    _notice(context, '未安装 QQ，分享链接已复制', XyNoticeType.warning);
    return;
  }

  // QQ 卡片缩略图需本地文件且不宜过大，压缩到 ≤256px JPEG 后再分享。
  var coverPath = '';
  try {
    final coverFile = await _localCoverFile(song);
    if (coverFile != null) {
      coverPath = (await _resizeCoverForShare(coverFile))?.path ?? coverFile.path;
    }
  } catch (_) {}

  final artist = song.artist.isEmpty ? '未知歌手' : song.artist;
  // QQ 好友场景走「音乐卡片」（QQ_SHARE_TYPE_AUDIO）：封面在左、歌名/歌手在右
  // 的对齐卡片，避免普通网页卡片那张「歌名左上、缩略图右下」的对角样式。
  // QQ 音乐卡片需 audio_url 才有向左对齐的封面；这里把落地页深链同时作为
  // audio_url 与 target_url，接收方点卡片即拉起 App 播放。QQ 空间不支持音乐卡片，
  // 仍走网页卡片。
  final useMusicCard = scene == _kSceneQQ;
  final result = await qq.share(
    scene: scene,
    title: song.title,
    summary: artist,
    targetUrl: url,
    coverPath: coverPath,
    musicUrl: useMusicCard ? url : null,
  );
  if (!context.mounted) return;

  switch (result) {
    case QqShareResult.success:
      _notice(context, '分享成功', XyNoticeType.success);
    case QqShareResult.canceled:
      _notice(context, '已取消分享', XyNoticeType.info);
    default:
      await Clipboard.setData(
          ClipboardData(text: _buildShareText(ref, song, url)));
      if (!context.mounted) return;
      _notice(context, '分享失败，链接已复制', XyNoticeType.warning);
  }
}

/// 取封面本地文件：优先本地封面（coverUrl 为 file:// 或绝对路径），
/// 其次在线封面（带浏览器 UA/Referer 直连，失败走 Rust 图片代理兜底，
/// 规避网易云等 CDN 的防盗链 403）。拿不到返回 null（此时仅分享文本链接）。
Future<File?> _localCoverFile(QueueItem song) async {
  final text = normalizeCoverImageUrl(song.coverUrl);
  if (text.isNotEmpty &&
      !text.startsWith('content://') &&
      !(text.startsWith('http://') || text.startsWith('https://'))) {
    try {
      var path = text;
      if (path.startsWith('file://')) path = path.substring('file://'.length);
      if (path.startsWith('//')) path = 'https:$path';
      final f = File(path);
      if (await f.exists()) return f;
    } catch (_) {}
  }
  if (text.startsWith('http://') || text.startsWith('https://')) {
    return _downloadCoverToTemp(text);
  }
  return null;
}

/// 下载在线封面到临时文件（QQ 卡片缩略图无法直接用远程防盗链 URL）。
Future<File?> _downloadCoverToTemp(String url) async {
  Uint8List? bytes = await _fetchCoverBytes(url);
  if (bytes == null || bytes.isEmpty) return null;
  try {
    final dir = Directory.systemTemp;
    final file = File(
        '${dir.path}/xy_share_${DateTime.now().millisecondsSinceEpoch}.jpg');
    await file.writeAsBytes(bytes);
    return file;
  } catch (_) {
    return null;
  }
}

/// 在线封面字节：先带浏览器请求头直连（网易云 CDN 对默认 UA 返回 403），
/// 失败后走 Rust 图片代理兜底（部分运营商网络直连 126.net 也会 403）。
Future<Uint8List?> _fetchCoverBytes(String url) async {
  try {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    final req = await client.getUrl(Uri.parse(url));
    final headers = coverImageNetworkHeaders(url);
    headers?.forEach(req.headers.set);
    final res = await req.close();
    if (res.statusCode == 200) {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in res) {
        builder.add(chunk);
      }
      client.close();
      final bytes = builder.takeBytes();
      if (bytes.isNotEmpty) return Uint8List.fromList(bytes);
    } else {
      client.close();
    }
  } catch (_) {}
  try {
    final dataUrl = await proxyImage(
      url: url,
      referer: 'https://music.163.com/',
    );
    final comma = dataUrl.indexOf(',');
    if (comma > 0 && dataUrl.substring(0, comma).contains(';base64')) {
      final decoded = base64Decode(dataUrl.substring(comma + 1));
      if (decoded.isNotEmpty) return decoded;
    }
  } catch (_) {}
  return null;
}

/// 压缩封面到 ≤256px JPEG（QQ 卡片缩略图规格，避免大图被 QQ 拒绝或拉取失败）。
/// 压缩失败返回 null，调用方回退原文件。
Future<File?> _resizeCoverForShare(File src) async {
  try {
    final decoded = img.decodeImage(await src.readAsBytes());
    if (decoded == null) return null;
    final longer =
        decoded.width > decoded.height ? decoded.width : decoded.height;
    img.Image out = decoded;
    if (longer > 256) {
      final scale = 256 / longer;
      out = img.copyResize(
        decoded,
        width: (decoded.width * scale).round(),
        height: (decoded.height * scale).round(),
      );
    }
    final dir = Directory.systemTemp;
    final file = File(
        '${dir.path}/xy_qq_${DateTime.now().millisecondsSinceEpoch}.jpg');
    await file.writeAsBytes(img.encodeJpg(out, quality: 85));
    return file;
  } catch (_) {
    return null;
  }
}
