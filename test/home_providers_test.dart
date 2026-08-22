import 'package:flutter_test/flutter_test.dart';
import 'package:xy_music/src/home/home_providers.dart';

void main() {
  test('解析网易云热评并提取歌曲名', () {
    final result = parseHotComment('念旧的人总是活得像个拾荒者——网易云热评《拾荒的人》');

    expect(result.comment, '念旧的人总是活得像个拾荒者');
    expect(result.songTitle, '拾荒的人');
    expect(formatHotCommentForDisplay(result.comment), '“念旧的人总是活得像个拾荒者”');
  });

  test('排行榜响应兼容 snake_case 并标识当前用户', () {
    final result = decodeLeaderboardData({
      'leaderboard': [
        {
          'rank': 1,
          'username': 'alice',
          'nickname': 'Alice',
          'duration': 7200,
          'is_me': 1,
        },
      ],
      'me': null,
      'total_users': 18,
    });

    expect(result.totalUsers, 18);
    expect(result.leaderboard.single.nickname, 'Alice');
    expect(result.leaderboard.single.isMe, isTrue);
  });
}
