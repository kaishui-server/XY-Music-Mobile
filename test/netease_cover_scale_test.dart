// 《一生一世》影视原声带封面不显示的回归测试。
// 根因：网易云 CDN picUrl 指向原始尺寸图片，该专辑封面原图 7.3MB，
// 超过 Rust 图片代理 5MB 上限被直接拒绝；系统媒体会话加载也会失败。
// 修复：normalizeCoverImageUrl 统一为 126.net 封面追加 ?param=800y800。
import 'package:flutter_test/flutter_test.dart';
import 'package:xy_music/src/widgets/cover_image.dart';
import 'package:xy_music/src/plugins/plugin_runtime.dart';

void main() {
  group('normalizeCoverImageUrl 网易云封面缩放', () {
    test('126.net 封面 URL 追加 param=800y800', () {
      const url =
          'https://p1.music.126.net/ttavCZZSzkgfM6E_ZizEkw==/109951166394487469.jpg';
      final result = normalizeCoverImageUrl(url);
      expect(result, contains('param=800y800'));
      expect(result, startsWith('https://p1.music.126.net/'));
    });

    test('已带 param 的 URL 不重复追加', () {
      const url =
          'https://p2.music.126.net/vmCcDvD1H04e9gm97xsCqg==/109951163350929740.jpg?param=300y300';
      expect(normalizeCoverImageUrl(url), url);
    });

    test('其他 CDN 域名不受影响', () {
      const url = 'https://imgcache.qq.com/cover/123.jpg';
      expect(normalizeCoverImageUrl(url), url);
      const kugou = 'http://imge.kugou.com/stdmusic/240/abc.jpg';
      // 仅协议升级为 HTTPS，域名保持不变。
      expect(normalizeCoverImageUrl(kugou), 'https://imge.kugou.com/stdmusic/240/abc.jpg');
    });

    test('http 协议升级与 param 追加共存', () {
      const url = 'http://p3.music.126.net/abc==/def.jpg';
      final result = normalizeCoverImageUrl(url);
      expect(result, startsWith('https://p3.music.126.net/'));
      expect(result, contains('param=800y800'));
    });

    test('空地址保持为空', () {
      expect(normalizeCoverImageUrl(null), '');
      expect(normalizeCoverImageUrl(''), '');
    });
  });

  group('picId 兜底生成的封面地址自带缩放参数', () {
    // _neteasePicIdToUrl 是私有方法，通过 _extractCover 的 picId 兜底
    // 路径间接验证：构建 rawData 只含 picId_str 的节点。
    test('搜索结果仅 picId_str 时生成的 URL 含 param', () {
      final result = PluginRuntimeService.extractCoverForTest({
        'picId_str': '109951166394487469',
      });
      expect(result, isNotEmpty);
      expect(result, contains('p1.music.126.net'));
      expect(result, contains('param=800y800'));
    });
  });

  group('网易云默认头像占位图过滤（歌手搜索结果头像修复）', () {
    const defaultTokenAvatar =
        'https://p1.music.126.net/uu_band_png/5639395138885805.jpg?param=300y300';
    const defaultWordAvatar =
        'https://p2.music.126.net/xxx/default.jpg?param=300y300';
    const realAvatar =
        'https://p4.music.126.net/_ECPuM0s0qtWhkpQOSTZUg==/109951169164936940.jpg';
    const realPicUrl =
        'https://p4.music.126.net/NWv6PtSBkyWZzqbJVzBr7g==/109951169164936450.jpg';

    test('avatar 为默认占位图时回退到 picUrl', () {
      final result = PluginRuntimeService.extractCoverForTest({
        'name': '周杰伦',
        'avatar': defaultTokenAvatar,
        'picUrl': realPicUrl,
      });
      // _extractCoverFromNode 键序 picUrl 先于 avatar，且 126.net
      // 统一追加 param=800y800 缩放参数。
      expect(result, startsWith(realPicUrl));
      expect(result, contains('param=800y800'));
      expect(result, isNot(contains('5639395138885805')));
    });

    test('avatar 与 picUrl 均为默认占位图时回退 picId_str 兜底', () {
      final result = PluginRuntimeService.extractCoverForTest({
        'name': '某歌手',
        'avatar': defaultTokenAvatar,
        'picUrl': defaultWordAvatar,
        'picId_str': '109951169164936940',
      });
      expect(result, isNotEmpty);
      expect(result, contains('109951169164936940'));
      expect(result, contains('param=800y800'));
      expect(result, isNot(contains('5639395138885805')));
    });

    test('仅默认占位图且无兜底字段时返回空', () {
      final result = PluginRuntimeService.extractCoverForTest({
        'name': '某歌手',
        'avatar': defaultTokenAvatar,
      });
      expect(result, isEmpty);
    });

    test('真实头像 URL 不被误过滤', () {
      // 仅含真实头像字段（无 picUrl 等前序键），验证默认头像过滤
      // 不误伤真实 126.net 头像。
      final result = PluginRuntimeService.extractCoverForTest({
        'name': '周杰伦',
        'avatar': realAvatar,
      });
      expect(result, startsWith(realAvatar));
      expect(result, contains('param=800y800'));
    });
  });

  group('歌手头像提取 _extractAvatar（对齐弦予候选键序）', () {
    const realAvatar =
        'https://p4.music.126.net/_ECPuM0s0qtWhkpQOSTZUg==/109951169164936940.jpg';
    const realImg1v1Url =
        'https://p1.music.126.net/vnCZkDnCdwF0zO5jXL5scA==/109951169164936450.jpg';
    const defaultTokenAvatar =
        'https://p1.music.126.net/uu_band_png/5639395138885805.jpg?param=300y300';

    test('网易云 weapi 歌手对象仅 img1v1Url 时提取成功', () {
      // 对齐弦予场景：网易云 search type=100 返回 img1v1Url 主头像字段。
      final result = PluginRuntimeService.extractAvatarForTest({
        'id': '6452',
        'name': '周杰伦',
        'img1v1Url': realImg1v1Url,
      });
      expect(result, startsWith(realImg1v1Url));
      expect(result, contains('param=800y800'));
    });

    test('avatarUrl 优先命中', () {
      final result = PluginRuntimeService.extractAvatarForTest({
        'name': 'Jay',
        'avatarUrl': realAvatar,
        'img1v1Url': realImg1v1Url,
      });
      expect(result, startsWith(realAvatar));
    });

    test('默认头像占位图回退到 img1v1Url', () {
      final result = PluginRuntimeService.extractAvatarForTest({
        'name': '周杰伦',
        'avatar': defaultTokenAvatar,
        'img1v1Url': realImg1v1Url,
      });
      expect(result, startsWith(realImg1v1Url));
      expect(result, isNot(contains('5639395138885805')));
    });

    test('全部头像键为空时回退通用封面（artwork 命中）', () {
      // animemusic suggest 歌手场景：后端只返回 artwork。
      final result = PluginRuntimeService.extractAvatarForTest({
        'id': '6452',
        'name': '周杰伦',
        'artwork': realAvatar,
      });
      expect(result, startsWith(realAvatar));
      expect(result, contains('param=800y800'));
    });

    test('仅默认占位图且无兜底时返回空', () {
      final result = PluginRuntimeService.extractAvatarForTest({
        'name': '某歌手',
        'avatar': defaultTokenAvatar,
      });
      expect(result, isEmpty);
    });
  });
}
