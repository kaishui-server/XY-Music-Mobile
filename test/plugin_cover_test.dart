import 'package:flutter_test/flutter_test.dart';
import 'package:xy_music/src/plugins/plugin_runtime.dart';

void main() {
  test('从嵌套 rawData/al.picId_str 生成网易云封面', () {
    final raw = <String, dynamic>{
      'rawData': {
        'id': '509781655',
        'al': {'picId_str': '109951163038292176'},
      },
    };

    expect(
      extractPluginCoverUrl(raw),
      'https://p1.music.126.net/'
      'yD9vbpuILH-tqNRIaP640g==/109951163038292176.jpg',
    );
  });

  test('识别 musicInfo/detail/album 深层封面', () {
    final raw = <String, dynamic>{
      'musicInfo': {
        'detail': {
          'album': {'blurPicUrl': '//p3.music.126.net/key/song.jpg'},
        },
      },
    };

    expect(extractPluginCoverUrl(raw), 'https://p3.music.126.net/key/song.jpg');
  });

  test('拒绝用丢失精度的 JS 大整数生成错误封面', () {
    expect(
      extractPluginCoverUrl({
        'album': {'picId': 109951163038292176},
      }),
      isEmpty,
    );
  });

  test('picId 加密结果与网易云官方封面一致', () {
    expect(
      neteasePicIdToCoverUrl('109951163038292176'),
      'https://p1.music.126.net/'
      'yD9vbpuILH-tqNRIaP640g==/109951163038292176.jpg',
    );
  });
}
