// 端到端验证酷狗歌单导入（对齐 WalnutBai lx-lxwalnut-music-mobile）。
// 直接调用真实酷狗接口验证完整流程。
//
// 运行：dart run tool/kg_import_check.dart

import 'dart:io';

import 'package:xy_music/src/plugins/lx_playlist_import.dart';

Future<void> main(List<String> args) async {
  final inputs = args.isNotEmpty
      ? args
      : [
          'https://m.kugou.com/songlist/gcid_3zcxy2wmz2z0d5/'
              '?src_cid=3zcxy2wmz2z0d5&uid=681244467&chl=message'
              '&cover=http://imge.kugou.com/stdmusic/20250101/'
              '20250101171655124318.jpg&iszlist=1',
          '39680537',
          '681244467',
        ];
  for (final input in inputs) {
    stdout.writeln('==> 导入：$input');
    try {
      final result = await importLxPlaylist(source: 'kg', idOrUrl: input);
      stdout.writeln('    歌单：${result.name}（${result.songs.length} 首）');
      stdout.writeln('    封面：${result.coverUrl}');
      for (final song in result.songs.take(3)) {
        final lx = song['lx'] as Map<String, dynamic>;
        final types = lx['_types'] as Map<String, dynamic>?;
        stdout.writeln(
          '    《${song['title']}》- ${song['artist']} '
          '${song['duration']}s 音质：${types?.keys.toList() ?? const []}',
        );
        if (types != null && types.isNotEmpty) {
          stdout.writeln('      详情：$types');
        }
      }
      final withQuality = result.songs
          .where((s) =>
              (s['lx'] as Map<String, dynamic>)['_types'] != null &&
              ((s['lx'] as Map<String, dynamic>)['_types']
                      as Map<String, dynamic>)
                  .isNotEmpty)
          .length;
      stdout.writeln(
        '    含音质详情歌曲数：$withQuality / ${result.songs.length}',
      );
    } catch (e) {
      stdout.writeln('    失败：$e');
    }
  }
}
