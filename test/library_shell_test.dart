import 'package:phototree/ui/album_tree_row.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/library/views.dart';
import 'package:phototree/media/browser.dart';
import 'package:phototree/organization/organization.dart';
import 'package:phototree/ui/library_shell.dart';
import 'package:phototree/ui/photo_grid.dart';
import 'package:phototree/ui/visual_style.dart';

import 'media_browser_test.dart' show photo;
import 'physical_operations_test.dart' show Harness;

void main() {
  late PhotoBrowser browser;
  late Organization org;

  Future<void> mount(
    WidgetTester t, {
    double width = 400,
    double height = 800,
    double scale = 1,
    Brightness brightness = Brightness.light,
    bool reduced = false,
    EdgeInsets safe = EdgeInsets.zero,
    Future<int?> Function()? read,
    Future<void> Function(int?)? save,
  }) async {
    final h = Harness();
    h.media.items = List.generate(120, (i) => photo(i + 1));
    h.media.image = () async => base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
    );
    await h.init();
    browser = h.browser;
    org = h.organization;
    t.view.physicalSize = Size(width, height);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(h.dispose);
    await t.pumpWidget(
      MaterialApp(
        theme: photoTreeTheme(brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: reduced,
            padding: safe,
          ),
          child: child!,
        ),
        home: LibraryShell(
          browser: browser,
          organization: org,
          favorites: h.favorites,
          physical: h.ops,
          readSidebarOpacity: read,
          saveSidebarOpacity: save,
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  Future<void> sidebar(WidgetTester t) async {
    await t.tap(find.byKey(const ValueKey('album-panel-toggle')));
    await t.pumpAndSettle();
  }

  Future<void> appearance(WidgetTester t) async {
    await t.tap(find.byTooltip('更多'));
    await t.pumpAndSettle();
    await t.ensureVisible(find.text('侧栏外观'));
    await t.pumpAndSettle();
    await t.tap(find.text('侧栏外观'));
    await t.pumpAndSettle();
  }

  testWidgets(
    'folder input remains reachable above a tall landscape keyboard',
    (t) async {
      await mount(
        t,
        width: 800,
        height: 320,
        scale: 2,
        safe: const EdgeInsets.only(top: 28),
      );
      await sidebar(t);
      await t.tap(find.byTooltip('新建'));
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('相册文件夹'));
      await t.pumpAndSettle();
      await t.tap(find.text('相册文件夹'));
      await t.pumpAndSettle();
      t.view.viewInsets = const FakeViewPadding(bottom: 210);
      addTearDown(t.view.resetViewInsets);
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('新建相册文件夹'));
      await t.pumpAndSettle();
      expect(find.text('新建相册文件夹').hitTestable(), findsOneWidget);
      await t.ensureVisible(find.byType(TextField));
      await t.pumpAndSettle();
      expect(find.byType(EditableText).hitTestable(), findsOneWidget);
      await t.enterText(find.byType(TextField), 'Landscape input');
      await t.pumpAndSettle();
      final dragStart = t.getCenter(find.byType(EditableText));
      for (
        var i = 0;
        i < 12 && find.text('取消').hitTestable().evaluate().isEmpty;
        i++
      ) {
        await t.dragFrom(dragStart, const Offset(0, -60));
        await t.pumpAndSettle();
      }
      expect(find.text('取消').hitTestable(), findsOneWidget);
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(org.snapshot.children(rootFolder), isEmpty);
      expect(t.takeException(), isNull);
    },
  );

  for (final config in [
    (400.0, 800.0, 1.0, Brightness.light),
    (400.0, 800.0, 1.3, Brightness.light),
    (400.0, 800.0, 1.0, Brightness.dark),
    (320.0, 640.0, 2.0, Brightness.dark),
    (640.0, 320.0, 2.0, Brightness.light),
  ]) {
    testWidgets(
      'browser controls and organization help remain usable $config',
      (t) async {
        await mount(
          t,
          width: config.$1,
          height: config.$2,
          scale: config.$3,
          brightness: config.$4,
          reduced: true,
        );
        final select = find.byTooltip('选择媒体');
        expect(t.getSize(select).height, greaterThanOrEqualTo(48));
        expect(
          find.descendant(
            of: select,
            matching: find.byIcon(Icons.check_box_outlined),
          ),
          findsOneWidget,
        );
        await t.tap(select);
        await t.pumpAndSettle();
        final all = find.text('全选');
        expect(all, findsOneWidget);
        expect(
          (t.getCenter(all) - t.getCenter(find.byTooltip('全选当前列表'))).distance,
          lessThanOrEqualTo(1),
        );
        await t.tap(find.byTooltip('退出选择'));
        await t.pumpAndSettle();
        for (final density in GridDensity.values) {
          await t.tap(find.byTooltip('更多'));
          await t.pumpAndSettle();
          final option = find.byKey(ValueKey('density-${density.name}'));
          if (config.$1 >= 360 && config.$3 == 1) {
            final menu = find
                .ancestor(
                  of: option,
                  matching: find.byType(SingleChildScrollView),
                )
                .first;
            expect(t.getSize(menu).width, 232);
            expect(t.getSize(option).height, 48);
          }
          final glyph = find.descendant(
            of: option,
            matching: find.byWidgetPredicate(
              (w) => w is SizedBox && w.width == 22 && w.height == 16,
            ),
          );
          final label = find.descendant(
            of: option,
            matching: find.byType(Text),
          );
          final a = t.getRect(glyph), b = t.getRect(label);
          expect(
            (a.expandToInclude(b).center.dy - t.getCenter(option).dy).abs(),
            lessThanOrEqualTo(1),
          );
          await t.ensureVisible(option);
          await t.pumpAndSettle();
          expect(t.getSize(option).height, greaterThanOrEqualTo(48));
          await t.tap(option);
          await t.pumpAndSettle();
          expect(t.widget<PhotoGrid>(find.byType(PhotoGrid)).density, density);
        }
        await sidebar(t);
        final before = org.snapshot;
        await t.tap(find.byTooltip('整理说明'));
        await t.pumpAndSettle();
        expect(find.text('长按并拖动，调整顺序'), findsOneWidget);
        expect(find.text('仅调整应用内分类，不移动照片文件。'), findsOneWidget);
        final close = find.widgetWithText(FilledButton, '知道了');
        expect(t.getRect(close).bottom, lessThanOrEqualTo(config.$2));
        expect(t.getRect(close).top, greaterThanOrEqualTo(0));
        await t.tap(close);
        await t.pumpAndSettle();
        expect(find.text('整理相册'), findsNothing);
        expect(org.snapshot, same(before));
        expect(t.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'heading plus keeps covers and shares creation location flow with footer',
    (t) async {
      await mount(t);
      await org.create(rootFolder, '旅行');
      await sidebar(t);
      final plus = find.byKey(const ValueKey('album-create-plus'));
      await t.ensureVisible(plus);
      final bounds = t.getRect(plus);
      expect(bounds.width, greaterThanOrEqualTo(48));
      expect(bounds.height, greaterThanOrEqualTo(48));
      final before = org.snapshot;
      await t.tap(plus);
      await t.pumpAndSettle();
      expect(find.text('根目录'), findsOneWidget);
      await t.tap(find.text('更改位置'));
      await t.pumpAndSettle();
      await t.tap(find.text('根目录 / 旅行'));
      await t.pumpAndSettle();
      expect(find.text('根目录 / 旅行'), findsOneWidget);
      await t.tap(find.text('相册文件夹'));
      await t.pumpAndSettle();
      expect(find.text('新建相册文件夹'), findsOneWidget);
      expect(find.text('根目录 / 旅行'), findsOneWidget);
      await t.enterText(find.byType(TextField), '新增文件夹');
      await t.tap(find.text('保存'));
      await t.pumpAndSettle();
      final parent = org.snapshot.folders.values
          .singleWhere((f) => f.name == '旅行')
          .id;
      expect(org.snapshot.children(parent).single.name, '新增文件夹');
      expect(identical(before, org.snapshot), isFalse);
      expect(find.text('新增文件夹'), findsOneWidget);
      final after = org.snapshot;
      await t.tap(find.byTooltip('新建'));
      await t.pumpAndSettle();
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(identical(after, org.snapshot), isTrue);
      final album = find.byKey(ValueKey(org.albums.single.key));
      await t.ensureVisible(album);
      expect(
        find.descendant(of: album, matching: find.byType(PhotoTile)),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'unavailable album stays readable and retryable in landscape text2 safe areas',
    (t) async {
      final h = Harness();
      h.media.image = () async => base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
      );
      await h.init();
      addTearDown(h.dispose);
      t.view.physicalSize = const Size(640, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final albumKey = h.organization.albums.single.key;
      await t.pumpWidget(
        MaterialApp(
          theme: photoTreeTheme(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
              padding: const EdgeInsets.only(top: 24, bottom: 24),
            ),
            child: child!,
          ),
          home: LibraryShell(
            browser: h.browser,
            organization: h.organization,
            physical: h.ops,
          ),
        ),
      );
      await t.pumpAndSettle();
      await sidebar(t);
      await t.tap(find.byKey(ValueKey(albumKey)));
      await t.pumpAndSettle();
      t.view.physicalSize = const Size(640, 320);
      h.media.items = [];
      await h.browser.refresh();
      await t.pumpAndSettle();
      expect(find.text('所选相册暂不可访问，未切换到其他同名相册'), findsOneWidget);
      expect(t.takeException(), isNull);
      final retry = find.text('重试 / 刷新');
      await t.ensureVisible(retry);
      h.media.items = [photo(1)];
      await t.tap(retry);
      await t.pumpAndSettle();
      expect(find.text('所选相册暂不可访问，未切换到其他同名相册'), findsNothing);
      expect(t.widget<PhotoGrid>(find.byType(PhotoGrid)).albumKey, albumKey);
      expect(find.byType(PhotoTile), findsWidgets);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'scrolling sidebar rows keeps selection paint out of the header',
    (t) async {
      await mount(
        t,
        width: 800,
        height: 320,
        scale: 2,
        safe: const EdgeInsets.all(24),
        read: () async => 70,
        save: (_) async {},
      );
      await appearance(t);
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pumpAndSettle();
      final panel = t.getRect(
        find.byKey(const ValueKey('album-management-panel')),
      );
      final headerPoint = Offset(panel.center.dx + 32, panel.top + 16);
      Future<List<int>> pixel() async => (await t.runAsync(() async {
        final image = await captureImage(t.element(find.byType(MaterialApp)));
        final data = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final offset =
            (headerPoint.dy.floor() * image.width + headerPoint.dx.floor()) * 4;
        final color = List<int>.generate(4, (i) => data.getUint8(offset + i));
        image.dispose();
        return color;
      }))!;
      final before = await pixel();
      final list = find.byKey(const ValueKey('album-management-list'));
      final favorite = find.byKey(const ValueKey('scope-favorite'));
      await t.scrollUntilVisible(
        favorite,
        50,
        scrollable: find.descendant(
          of: list,
          matching: find.byType(Scrollable),
        ),
      );
      await Scrollable.ensureVisible(t.element(favorite), alignment: .5);
      await t.pumpAndSettle();
      expect(t.getRect(list).top, greaterThan(headerPoint.dy));
      expect(
        await pixel(),
        before,
        reason: 'Scrolling selection behind the sidebar header must not repaint that fixed header.',
      );
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'appearance settings use the sidebar bottom and tree gets remaining height',
    (t) async {
      await mount(t, height: 1000, read: () async => 86, save: (_) async {});
      for (var i = 0; i < 20; i++) {
        await org.create(rootFolder, '文件夹 $i');
      }
      await appearance(t);
      final panel = t.getRect(
        find.byKey(const ValueKey('album-management-panel')),
      );
      expect(panel.top, 64);
      expect(1000 - panel.bottom, panel.top);
      final settings = t.getRect(
        find.ancestor(
          of: find.byType(Slider),
          matching: find.byType(SingleChildScrollView),
        ),
      );
      final tree = t.getRect(
        find.byKey(const ValueKey('album-management-list')),
      );
      expect(
        settings.bottom,
        closeTo(panel.bottom, 1),
        reason:
            'settings=$settings panel=$panel tree=$tree; settings must reach the bottom instead of leaving an unused flex share',
      );
      expect(tree.height, greaterThan(panel.height * .60));
      await t.tap(find.text('收起设置'));
      await t.pumpAndSettle();
      final creation = t.getRect(find.byTooltip('新建'));
      final collapsedTree = t.getRect(
        find.byKey(const ValueKey('album-management-list')),
      );
      expect(creation.bottom, closeTo(panel.bottom, 1));
      expect(collapsedTree.bottom, closeTo(creation.top, 1));
      expect(collapsedTree.height, greaterThan(tree.height));
    },
  );

  testWidgets(
    'scope navigation resets selection, retains separate anchors and does not scan',
    (t) async {
      await mount(t);
      final generation = browser.generation;
      final grid = find.byType(PhotoGrid);
      await t.drag(
        find.byKey(const ValueKey('photo-grid')),
        const Offset(0, -720),
      );
      await t.pumpAndSettle();
      final position = t.widget<PhotoGrid>(grid).position!;
      final anchor = position.anchor;
      final relative = position.relative;
      final state = t.state(grid);
      await t.tap(find.byTooltip('选择媒体'));
      await t.pumpAndSettle();
      await sidebar(t);
      await t.tap(find.byKey(const ValueKey('sidebar-close')));
      await t.pumpAndSettle();
      expect(identical(t.state(grid), state), isTrue);
      expect(find.byTooltip('退出选择'), findsOneWidget);
      await sidebar(t);
      await t.tap(find.byKey(const ValueKey('scope-favorite')));
      await t.pumpAndSettle();
      expect(t.widget<PhotoGrid>(grid).view, LibraryView.favorite);
      expect(identical(t.state(grid), state), isFalse);
      expect(find.byTooltip('退出选择'), findsNothing);
      await sidebar(t);
      await t.tap(find.byKey(const ValueKey('scope-all')));
      await t.pumpAndSettle();
      expect(t.widget<PhotoGrid>(grid).position, same(position));
      expect(position.anchor, anchor);
      expect(position.relative, closeTo(relative, 1));
      expect(find.byTooltip('退出选择'), findsNothing);
      expect(browser.generation, generation);
    },
  );

  testWidgets(
    'album section chooses top-level creation without a persistent root row',
    (t) async {
      await mount(t);
      await org.create(rootFolder, '旅行');
      final folder = org.snapshot.children(rootFolder).single.id;
      await sidebar(t);
      expect(find.text('根相册文件夹'), findsNothing);
      expect(find.byKey(const ValueKey('root-folder')), findsNothing);
      await t.tap(find.byKey(ValueKey('folder-$folder')));
      await t.pumpAndSettle();
      expect(find.text('新建位置：根目录 / 旅行'), findsOneWidget);
      final heading = find.byKey(const ValueKey('album-section-heading'));
      await t.tap(heading);
      await t.pumpAndSettle();
      expect(find.text('新建位置：根目录'), findsOneWidget);
      expect(
        find.descendant(of: heading, matching: find.text('相册')),
        findsOneWidget,
      );
      expect(t.widget<ListTile>(heading).selected, isFalse);
      expect(t.widget<PhotoGrid>(find.byType(PhotoGrid)).view, LibraryView.all);
      await t.tap(find.byTooltip('新建'));
      await t.pumpAndSettle();
      await t.tap(find.text('相册文件夹'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), '顶层新建');
      await t.tap(find.text('保存'));
      await t.pumpAndSettle();
      expect(
        org.snapshot.children(rootFolder).map((f) => f.name),
        contains('顶层新建'),
      );
      expect(org.snapshot.children(folder), isEmpty);
    },
  );

  testWidgets(
    'slider preview and save leave the grid widget and media generation untouched',
    (t) async {
      final saved = <int?>[];
      await mount(
        t,
        read: () async => 86,
        save: (value) async => saved.add(value),
      );
      await appearance(t);
      final grid = t.widget<PhotoGrid>(find.byType(PhotoGrid));
      final generation = browser.generation;
      final slider = find.byKey(const ValueKey('sidebar-opacity'));
      await t.drag(slider, const Offset(-50, 0));
      await t.pumpAndSettle();
      t.widget<Slider>(slider).onChanged!(40);
      t.widget<Slider>(slider).onChangeEnd!(40);
      await t.pumpAndSettle();
      final value = t.widget<Slider>(slider).value.round();
      expect(value, lessThan(86));
      expect(saved.last, value);
      expect(value, 70);
      final backing = t.widgetList<DecoratedBox>(
        find.byKey(const ValueKey('sidebar-text-backing')),
      );
      expect(backing, isEmpty);
      for (final surface in backing) {
        expect(
          (surface.decoration as BoxDecoration).color!.a,
          closeTo(.9, .001),
        );
      }
      expect(
        identical(t.widget<PhotoGrid>(find.byType(PhotoGrid)), grid),
        isTrue,
      );
      expect(browser.generation, generation);
      expect(
        find.byKey(const ValueKey('album-management-panel')),
        findsOneWidget,
      );
      expect(
        t
            .widget<GlassSurface>(
              find.byKey(const ValueKey('album-management-panel')),
            )
            .opacity,
        value / 100,
      );
    },
  );

  testWidgets(
    'late preference read cannot overwrite a user adjustment or default reset',
    (t) async {
      final loaded = Completer<int?>();
      final saved = <int?>[];
      await mount(
        t,
        read: () => loaded.future,
        save: (v) async => saved.add(v),
      );
      await appearance(t);
      final slider = find.byKey(const ValueKey('sidebar-opacity'));
      t.widget<Slider>(slider).onChanged!(74);
      await t.pump();
      await t.tap(find.text('恢复默认'));
      await t.pumpAndSettle();
      loaded.complete(98);
      await t.pumpAndSettle();
      expect(t.widget<Slider>(slider).value, 86);
      expect(saved, [null]);
    },
  );

  testWidgets(
    'preference writes serialize latest completed gesture and finish after disposal',
    (t) async {
      final gate = Completer<void>();
      final writes = <int?>[];
      await mount(
        t,
        save: (value) async {
          writes.add(value);
          if (writes.length == 1) await gate.future;
        },
      );
      await appearance(t);
      var slider = t.widget<Slider>(find.byType(Slider));
      slider.onChanged!(75);
      slider.onChangeEnd!(75);
      await t.pump();
      slider = t.widget<Slider>(find.byType(Slider));
      slider.onChanged!(85);
      slider.onChangeEnd!(85);
      slider.onChanged!(93);
      slider.onChangeEnd!(93);
      await t.pump();
      expect(writes, [75]);
      await t.pumpWidget(const SizedBox());
      gate.complete();
      await t.pumpAndSettle();
      expect(writes, [75, 93]);
      expect(t.takeException(), isNull);
    },
  );

  for (final legacy in [40, 55, 69, 70, 100]) {
    testWidgets('legacy opacity $legacy migrates without changing media', (
      t,
    ) async {
      final writes = <int?>[];
      await mount(
        t,
        read: () async => legacy,
        save: (v) async => writes.add(v),
      );
      final generation = browser.generation;
      await appearance(t);
      final slider = t.widget<Slider>(find.byType(Slider));
      expect(slider.min, 70);
      expect(slider.max, 100);
      expect(slider.divisions, 30);
      expect(slider.value, legacy.clamp(70, 100));
      expect(writes, legacy < 70 ? [70] : isEmpty);
      expect(browser.generation, generation);
    });
  }

  testWidgets('migration failure keeps safe preview and retries latest value', (
    t,
  ) async {
    var fail = true;
    final writes = <int?>[];
    await mount(
      t,
      read: () async => 55,
      save: (v) async {
        writes.add(v);
        if (fail) throw StateError('migration failure');
      },
    );
    await appearance(t);
    expect(t.widget<Slider>(find.byType(Slider)).value, 70);
    expect(find.text('保存失败，仅本次生效'), findsOneWidget);
    fail = false;
    await t.tap(find.text('重试设置'));
    await t.pumpAndSettle();
    expect(writes, [70, 70]);
    expect(find.text('保存失败，仅本次生效'), findsNothing);
  });

  testWidgets('late legacy read does not replace a new user choice', (t) async {
    final read = Completer<int?>();
    final writes = <int?>[];
    await mount(t, read: () => read.future, save: (v) async => writes.add(v));
    await appearance(t);
    final slider = t.widget<Slider>(find.byType(Slider));
    slider.onChanged!(93);
    slider.onChangeEnd!(93);
    read.complete(40);
    await t.pumpAndSettle();
    expect(t.widget<Slider>(find.byType(Slider)).value, 93);
    expect(writes, [93]);
  });

  testWidgets(
    'failed preference save keeps preview and offers a working retry',
    (t) async {
      var fail = true;
      final writes = <int?>[];
      await mount(
        t,
        save: (value) async {
          writes.add(value);
          if (fail) throw StateError('test write failure');
        },
      );
      await appearance(t);
      final slider = t.widget<Slider>(find.byType(Slider));
      slider.onChanged!(70);
      slider.onChangeEnd!(70);
      await t.pumpAndSettle();
      expect(find.text('保存失败，仅本次生效'), findsOneWidget);
      expect(t.widget<Slider>(find.byType(Slider)).value, 70);
      fail = false;
      await t.tap(find.text('重试设置'));
      await t.pumpAndSettle();
      expect(find.text('保存失败，仅本次生效'), findsNothing);
      expect(writes, [70, 70]);
    },
  );

  testWidgets(
    'failed preference read is visible and can retry without changing media',
    (t) async {
      var fail = true;
      await mount(
        t,
        read: () async {
          if (fail) throw const FormatException('test corruption');
          return 92;
        },
      );
      await appearance(t);
      expect(find.text('读取设置失败，当前使用默认值'), findsOneWidget);
      fail = false;
      await t.tap(find.text('重试设置'));
      await t.pumpAndSettle();
      expect(t.widget<Slider>(find.byType(Slider)).value, 92);
      expect(find.text('读取设置失败，当前使用默认值'), findsNothing);
    },
  );

  testWidgets(
    'five-level selected album keeps its count and details reachable at320 text2',
    (t) async {
      await mount(t, width: 320, scale: 2, reduced: true);
      var parent = rootFolder;
      final ids = <String>[];
      for (var depth = 0; depth < 5; depth++) {
        await org.create(parent, '第${depth + 1}层名称较长的相册文件夹');
        parent = org.snapshot.children(parent).single.id;
        ids.add(parent);
      }
      final album = org.albums.single;
      await org.moveAlbum(album.key, parent, generation: browser.generation);
      await sidebar(t);
      for (final id in ids) {
        final row = find.byKey(ValueKey('folder-$id'));
        await t.ensureVisible(row);
        await t.tap(row);
        await t.pumpAndSettle();
      }
      // Sidebar rows never expose paths/status as subtitles, even deep in a tree.
      for (final sidebarRow in t.widgetList<AlbumTreeRow>(
        find.byType(AlbumTreeRow),
      )) {
        expect(sidebarRow.subtitle, isNull);
      }
      final row = find.byKey(ValueKey(album.key));
      await t.ensureVisible(row);
      await t.tap(row);
      await t.pumpAndSettle();
      await sidebar(t);
      await t.ensureVisible(row);
      expect(t.widget<AlbumTreeRow>(row).selected, isTrue);
      expect(
        find.descendant(of: row, matching: find.text('120')),
        findsOneWidget,
      );
      final menu = find.byTooltip('管理 ${album.name}');
      await t.tap(menu);
      await t.pumpAndSettle();
      await t.tap(find.text('相册详情'));
      await t.pumpAndSettle();
      expect(find.byType(SelectableText), findsOneWidget);
      expect(find.text(album.directory), findsOneWidget);
      await t.tap(find.text('关闭'));
      await t.pumpAndSettle();
      final folderMenu = find.byTooltip('管理 第5层名称较长的相册文件夹');
      await t.ensureVisible(folderMenu);
      await t.tap(folderMenu);
      await t.pumpAndSettle();
      await t.tap(find.text('文件夹路径'));
      await t.pumpAndSettle();
      expect(
        t.widget<SelectableText>(find.byType(SelectableText)).data,
        contains('第1层名称较长的相册文件夹 / 第2层'),
      );
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('landscape text2 keeps creation and appearance retry reachable', (
    t,
  ) async {
    var fail = true;
    await mount(
      t,
      width: 800,
      height: 320,
      scale: 2,
      reduced: true,
      read: () async {
        if (fail) throw const FormatException('test corrupt preferences');
        return 70;
      },
    );
    await appearance(t);
    expect(t.takeException(), isNull);
    expect(find.textContaining('减少效果已开启'), findsOneWidget);
    await t.ensureVisible(find.text('重试设置'));
    fail = false;
    await t.tap(find.text('重试设置'));
    await t.pumpAndSettle();
    expect(t.widget<Slider>(find.byType(Slider)).value, 70);
    await t.ensureVisible(find.text('恢复默认'));
    await t.tap(find.text('恢复默认'));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('新建'));
    await t.pumpAndSettle();
    expect(find.text('相册文件夹'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  for (final size in [
    const Size(320, 640),
    const Size(360, 640),
    const Size(412, 640),
    const Size(640, 320),
  ]) {
    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets(
        'creation menu remains compact and cancel reachable $size scale $scale',
        (t) async {
          await mount(t, width: size.width, height: size.height, scale: scale);
          await sidebar(t);
          await t.tap(find.byTooltip('新建'));
          await t.pumpAndSettle();
          expect(t.takeException(), isNull);
          final surface = t.getRect(
            find.byKey(const ValueKey('creation-menu')),
          );
          expect(surface.width, lessThanOrEqualTo(360));
          final cancel = find.widgetWithText(TextButton, '取消');
          expect(t.getRect(cancel).bottom, lessThanOrEqualTo(size.height));
          expect(t.getSize(cancel).height, greaterThanOrEqualTo(48));
          final before = org.snapshot;
          await t.tap(cancel);
          await t.pumpAndSettle();
          expect(identical(before, org.snapshot), isTrue);
        },
      );
    }
  }

  for (final width in [320.0, 360.0, 412.0]) {
    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets(
        'sidebar and appearance controls fit width $width text $scale',
        (t) async {
          await mount(
            t,
            width: width,
            scale: scale,
            reduced: true,
            brightness: scale == 2 ? Brightness.dark : Brightness.light,
          );
          await org.create(rootFolder, '一个名称较长的相册文件夹');
          await appearance(t);
          expect(
            t
                .getSize(find.byKey(const ValueKey('album-management-panel')))
                .width,
            closeTo(width * .74 > 320 ? 320 : width * .74, .01),
          );
          expect(find.byType(Slider), findsOneWidget);
          await t.ensureVisible(find.text('恢复默认'));
          await t.tap(find.text('恢复默认'));
          await t.pumpAndSettle();
          expect(t.takeException(), isNull);
        },
      );
    }
  }
}
