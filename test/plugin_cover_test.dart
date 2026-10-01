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
      'yD9vbpuILH-tqNRIaP640g==/109951163038292176.jpg?param=800y800',
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

    expect(
      extractPluginCoverUrl(raw),
      'https://p3.music.126.net/key/song.jpg?param=800y800',
    );
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
      'yD9vbpuILH-tqNRIaP640g==/109951163038292176.jpg?param=800y800',
    );
  });

  test('B站图床头像剥离 @缩略后缀还原原图', () {
    // B站插件返回的 UP 主头像常带 @160w_160h_1c_1s.avif 缩略后缀，
    // AVIF 多数设备解码失败会显示占位图；插件自身的剥离逻辑依赖
    // quickjs 不存在的 URL 类而失效，由宿主统一剥离。
    expect(
      extractPluginCoverUrl({
        'avatar': '//i0.hdslb.com/bfs/face/abc123.jpg@160w_160h_1c_1s.avif',
      }),
      'https://i0.hdslb.com/bfs/face/abc123.jpg',
    );
    // 视频封面同理（web-search-common-cover 等缩略形式）。
    expect(
      extractPluginCoverUrl({
        'artwork':
            'https://i2.hdslb.com/bfs/archive/x.jpg'
            '@320w_180h_1c_!web-search-common-cover.avif',
      }),
      'https://i2.hdslb.com/bfs/archive/x.jpg',
    );
    // 非 B站图床、@ 在路径中间的地址不受影响。
    expect(
      extractPluginCoverUrl({
        'avatar': 'https://p2.music.126.net/key/face@2x.jpg',
      }),
      'https://p2.music.126.net/key/face@2x.jpg?param=800y800',
    );
    expect(
      extractPluginCoverUrl({
        'avatar': 'https://i2.hdslb.com/bfs/face/a@b/c.jpg',
      }),
      'https://i2.hdslb.com/bfs/face/a@b/c.jpg',
    );
  });
}
