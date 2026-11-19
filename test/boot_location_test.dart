import 'package:flutter_test/flutter_test.dart';
import 'package:xy_music/src/core/settings.dart';
import 'package:xy_music/src/navigation/boot_location.dart';

void main() {
  group('bootLocationFor', () {
    test('默认排序落在首页', () {
      expect(
        bootLocationFor(
          sidebarItemOrder: kDefaultSidebarItemOrder,
          bottomBarItemIds: const [],
          sidebarHiddenItems: const [],
          bottomBarEnabled: false,
        ),
        '/home',
      );
    });

    test('跟随侧栏排序首项', () {
      expect(
        bootLocationFor(
          sidebarItemOrder: const [
            kSidebarMusicLibrary,
            kSidebarHome,
            kSidebarSettings,
          ],
          bottomBarItemIds: const [],
          sidebarHiddenItems: const [],
          bottomBarEnabled: false,
        ),
        '/music-library',
      );
      expect(
        bootLocationFor(
          sidebarItemOrder: const [kSidebarSettings, kSidebarHome],
          bottomBarItemIds: const [],
          sidebarHiddenItems: const [],
          bottomBarEnabled: false,
        ),
        '/settings',
      );
    });

    test('排序里缺失的 id 由 normalize 补齐且不影响首项', () {
      expect(
        bootLocationFor(
          sidebarItemOrder: const [kSidebarDownloads],
          bottomBarItemIds: const [],
          sidebarHiddenItems: const [],
          bottomBarEnabled: false,
        ),
        '/settings/tasks',
      );
    });

    test('侧栏隐藏且不在底栏的入口不作为落点', () {
      expect(
        bootLocationFor(
          sidebarItemOrder: const [
            kSidebarPlugins,
            kSidebarMusicLibrary,
            kSidebarHome,
          ],
          bottomBarItemIds: const [],
          sidebarHiddenItems: const [kSidebarPlugins],
          bottomBarEnabled: false,
        ),
        '/music-library',
      );
    });

    test('侧栏隐藏但出现在底栏时仍可作为落点', () {
      expect(
        bootLocationFor(
          sidebarItemOrder: const [
            kSidebarPlugins,
            kSidebarHome,
            kSidebarMusicLibrary,
          ],
          bottomBarItemIds: const [kSidebarHome, kSidebarPlugins],
          sidebarHiddenItems: const [kSidebarPlugins],
          bottomBarEnabled: true,
        ),
        '/home',
      );
    });

    test('底栏启用时底栏条目排在最前', () {
      expect(
        bootLocationFor(
          sidebarItemOrder: const [kSidebarHome, kSidebarMusicLibrary],
          bottomBarItemIds: const [kSidebarExplore, kSidebarHome],
          sidebarHiddenItems: const [],
          bottomBarEnabled: true,
        ),
        '/home/explore',
      );
    });

    test('底栏只有一条时不算启用，回退侧栏顺序', () {
      expect(
        bootLocationFor(
          sidebarItemOrder: const [kSidebarRecognize, kSidebarHome],
          bottomBarItemIds: const [kSidebarSettings],
          sidebarHiddenItems: const [],
          bottomBarEnabled: true,
        ),
        '/home/recognize',
      );
    });

    test('排序首项被隐藏时顺延到下一个可见入口', () {
      // home 被隐藏后，normalize 补齐的 explore 顶上成为落点。
      expect(
        bootLocationFor(
          sidebarItemOrder: const [kSidebarHome],
          bottomBarItemIds: const [],
          sidebarHiddenItems: const [kSidebarHome],
          bottomBarEnabled: false,
        ),
        '/home/explore',
      );
      expect(
        bootLocationFor(
          sidebarItemOrder: const [kSidebarHome],
          bottomBarItemIds: const [],
          sidebarHiddenItems: const [kSidebarHome, kSidebarExplore],
          bottomBarEnabled: false,
        ),
        '/music-library',
      );
    });

    test('空排序列表按默认顺序落首页', () {
      expect(
        bootLocationFor(
          sidebarItemOrder: const [],
          bottomBarItemIds: const [],
          sidebarHiddenItems: const [],
          bottomBarEnabled: false,
        ),
        '/home',
      );
    });
  });

  group('bootVisibleItemIds', () {
    test('底栏启用时底栏条目在前且不重复', () {
      final ids = bootVisibleItemIds(
        sidebarItemOrder: const [kSidebarHome, kSidebarSettings],
        bottomBarItemIds: const [kSidebarSettings, kSidebarHome],
        bottomBarEnabled: true,
      );
      // 底栏两条按底栏自身顺序排在最前，其余入口随后补齐。
      expect(ids.take(2).toList(), [kSidebarSettings, kSidebarHome]);
      // 归一化会把缺失入口补到末尾，但同一个 id 不能出现两次。
      expect(ids.toSet().length, ids.length);
      expect(ids.length, kDefaultSidebarItemOrder.length);
    });

    test('底栏未启用时等于归一化后的侧栏顺序', () {
      expect(
        bootVisibleItemIds(
          sidebarItemOrder: const [kSidebarSettings, 'unknown'],
          bottomBarItemIds: const [kSidebarHome, kSidebarMusicLibrary],
          bottomBarEnabled: false,
        ),
        normalizeSidebarItemOrder(const [kSidebarSettings, 'unknown']),
      );
    });
  });
}
