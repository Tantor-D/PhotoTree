import 'package:phototree/ui/album_tree_row.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/media/browser.dart';
import 'package:phototree/media/media_source.dart';
import 'package:phototree/organization/organization.dart';
import 'package:phototree/ui/library_shell.dart';
import 'package:phototree/ui/organization_order.dart';
import 'package:phototree/ui/photo_grid.dart';
import 'package:phototree/ui/photo_viewer.dart';

import 'organization_test.dart' show MemoryOrganization;
import 'media_browser_test.dart' show FakeMedia, photo;

void main() {
  late FakeMedia source;
  late PhotoBrowser browser;
  late MemoryOrganization store;
  late Organization org;
  Future<void> initialize() async {
    source = FakeMedia()
      ..items = [photo(1)]
      ..image = () async => base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
      );
    browser = PhotoBrowser(source);
    await browser.refresh();
    store = MemoryOrganization();
    org = Organization(store, browser);
    await org.load();
  }

  tearDown(() {
    org.dispose();
    browser.dispose();
  });
  Future<void> show(WidgetTester t) async {
    await t.pumpWidget(
      MaterialApp(
        home: LibraryShell(organization: org, browser: browser),
      ),
    );
    await t.pumpAndSettle();
    if (org.phase == OrganizationPhase.ready) {
      await t.tap(find.byKey(const ValueKey('album-panel-toggle')));
      await t.pumpAndSettle();
    }
  }

  // Retain the former page's low-level contract regressions. It is not a
  // product navigation entry or evidence for the new immediate-save card.
  Future<void> showLegacyOrder(WidgetTester t) async {
    await t.pumpWidget(
      MaterialApp(
        key: UniqueKey(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => OrganizationOrderPage(
                    organization: org,
                    browser: browser,
                    parent: rootFolder,
                  ),
                ),
              ),
              child: const Text('Open legacy order regression'),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('Open legacy order regression'));
    await t.pumpAndSettle();
  }

  Future<void> openDissolution(WidgetTester t, String name) async {
    await t.tap(find.byTooltip('管理 $name'));
    await t.pumpAndSettle();
    await t.tap(find.text('解散文件夹'));
    await t.pumpAndSettle();
  }

  testWidgets(
    'album menu places album in folder and dissolution preserves its photos',
    (t) async {
      await initialize();
      await org.create(rootFolder, 'Trip');
      final folder = org.snapshot.children(rootFolder).single.id;
      final album = org.albums.single;
      final originalPhotos = List<Photo>.of(browser.photos);
      await show(t);
      await t.tap(find.byTooltip('管理 ${album.name}'));
      await t.pumpAndSettle();
      await t.tap(find.text('移到文件夹'));
      await t.pumpAndSettle();
      expect(find.text('根目录'), findsOneWidget);
      expect(find.text('Trip'), findsWidgets);
      await t.tap(find.byKey(ValueKey('target-$folder')));
      await t.pumpAndSettle();
      expect(org.snapshot.parentOfAlbum(album.key), rootFolder);
      await t.tap(find.byKey(const ValueKey('use-target-folder')));
      await t.pumpAndSettle();
      expect(org.snapshot.parentOfAlbum(album.key), folder);
      expect(find.byKey(ValueKey(album.key)), findsNothing);
      await t.tap(find.byKey(ValueKey('folder-$folder')));
      await t.pumpAndSettle();
      expect(find.byKey(ValueKey(album.key)), findsOneWidget);
      await openDissolution(t, 'Trip');
      await t.tap(find.text('确认解散'));
      await t.pumpAndSettle();
      expect(org.snapshot.parentOfAlbum(album.key), rootFolder);
      expect(find.byKey(ValueKey(album.key)), findsOneWidget);
      expect(browser.photos, originalPhotos);
    },
  );
  testWidgets('albums tab opens management sidebar without scanning', (
    t,
  ) async {
    await initialize();
    final generation = browser.generation;
    await t.pumpWidget(
      MaterialApp(
        home: LibraryShell(browser: browser, organization: org),
      ),
    );
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('album-panel-toggle')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('album-panel-toggle')));
    await t.pumpAndSettle();
    expect(find.widgetWithText(AlbumTreeRow, 'A'), findsOneWidget);
    expect(find.text(source.items.single.albumKey), findsNothing);
    expect(browser.generation, generation);
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets(
    'handle drag reorders only its group; folder back stays on albums',
    (t) async {
      await initialize();
      await org.create(rootFolder, 'First');
      await org.create(rootFolder, 'Second');
      await showLegacyOrder(t);
      final handle = find.byType(ReorderableDelayedDragStartListener).first;
      final gesture = await t.startGesture(t.getCenter(handle));
      await t.pump(const Duration(milliseconds: 600));
      await gesture.moveBy(const Offset(0, 1));
      await t.pump();
      await gesture.moveBy(const Offset(0, 150));
      await t.pump(const Duration(milliseconds: 400));
      await gesture.up();
      await t.pumpAndSettle();
      await t.tap(find.text('保存'));
      await t.pumpAndSettle();
      expect(org.snapshot.children(rootFolder).map((f) => f.name), [
        'Second',
        'First',
      ]);
      await t.pumpWidget(
        MaterialApp(
          home: LibraryShell(browser: browser, organization: org),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('album-panel-toggle')));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(AlbumTreeRow, 'First'));
      await t.pumpAndSettle();
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('album-panel-toggle')), findsOneWidget);
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byType(PhotoGrid), findsOneWidget);
    },
  );

  testWidgets('large text keeps create and order actions reachable', (t) async {
    await initialize();
    await org.create(rootFolder, '较长的相册文件夹名称');
    await t.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: LibraryShell(organization: org, browser: browser),
      ),
    );
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    await t.tap(find.byKey(const ValueKey('album-panel-toggle')));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('新建'));
    await t.pumpAndSettle();
    expect(find.text('相册文件夹'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'ordinary refresh retains root album and navigation does not rescan',
    (t) async {
      await initialize();
      await show(t);
      final pending = Completer<List<Photo>>();
      var scans = 0;
      source.query = (after) async {
        if (after != 0) return [];
        scans++;
        return pending.future;
      };
      final refreshing = browser.refresh();
      await t.pump();
      expect(browser.updating, isTrue);
      expect(find.widgetWithText(AlbumTreeRow, 'A'), findsOneWidget);
      pending.complete(source.items);
      await refreshing;
      await t.pumpAndSettle();
      for (var i = 0; i < 10; i++) {
        await t.tap(find.widgetWithText(AlbumTreeRow, 'A'));
        await t.pumpAndSettle();
        await t.tap(find.byKey(const ValueKey('album-panel-toggle')));
        await t.pumpAndSettle();
      }
      expect(scans, 1);
      expect(find.widgetWithText(AlbumTreeRow, 'A'), findsOneWidget);
    },
  );

  testWidgets('long order drag autoscrolls across the viewport', (t) async {
    await initialize();
    for (var i = 0; i < 30; i++) {
      await org.create(rootFolder, 'Folder ${i.toString().padLeft(2, '0')}');
    }
    final first = org.snapshot.children(rootFolder).first.id;
    await showLegacyOrder(t);
    final gesture = await t.startGesture(
      t.getCenter(find.byType(ReorderableDelayedDragStartListener).first),
    );
    await t.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(const Offset(750, 590));
    for (var i = 0; i < 50; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    await gesture.up();
    await t.pumpAndSettle();
    await t.tap(find.text('保存'));
    await t.pumpAndSettle();
    expect(
      org.snapshot.children(rootFolder).indexWhere((f) => f.id == first),
      greaterThan(10),
    );
  });

  testWidgets(
    'narrow large text order keeps same-name paths and actions visible',
    (t) async {
      await initialize();
      source.items = [
        photo(1, directory: 'Pictures/这是一个较长的第一组目录/Same/'),
        photo(2, directory: 'Pictures/这是一个较长的第二组目录/Same/'),
      ];
      await browser.refresh();
      await t.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: OrganizationOrderPage(
            organization: org,
            browser: browser,
            parent: rootFolder,
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(t.takeException(), isNull);
      expect(find.textContaining('第一组目录'), findsOneWidget);
      await t.tap(find.byTooltip('调整 Same').first);
      await t.pumpAndSettle();
      expect(find.text('下移'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    '013 current folder confirmation cancels, then dissolves to parent',
    (t) async {
      await initialize();
      await org.create(rootFolder, 'Trip');
      final id = org.snapshot.folders.keys.single;
      await org.create(id, 'Child');
      await org.moveAlbum(
        source.items.single.albumKey,
        id,
        generation: browser.generation,
      );
      await show(t);
      expect(find.byTooltip('解散当前相册文件夹'), findsNothing);
      await t.tap(find.byKey(ValueKey('folder-$id')));
      await t.pumpAndSettle();
      final before = org.snapshot;
      await openDissolution(t, 'Trip');
      expect(find.textContaining('直接子文件夹：1 个'), findsOneWidget);
      expect(find.textContaining('归类相册：1 个'), findsOneWidget);
      expect(find.textContaining('保留相册，移到上一级：根目录'), findsOneWidget);
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(org.snapshot, same(before));
      await openDissolution(t, 'Trip');
      await t.tap(find.text('确认解散'));
      await t.pumpAndSettle();
      expect(org.snapshot.exists(id), false);
      expect(find.byTooltip('解散当前相册文件夹'), findsNothing);
      expect(find.widgetWithText(AlbumTreeRow, 'Child'), findsOneWidget);
      expect(find.widgetWithText(AlbumTreeRow, 'A'), findsOneWidget);
    },
  );
  testWidgets(
    '013 stale confirmation rejects; ancestor dissolution preserves open viewer anchor and descendant path',
    (t) async {
      await initialize();
      await org.create(rootFolder, 'Trip');
      final id = org.snapshot.folders.keys.single;
      await org.create(id, 'Child');
      final child = org.snapshot.children(id).single.id;
      await org.moveAlbum(
        source.items.single.albumKey,
        child,
        generation: browser.generation,
      );
      await show(t);
      await t.tap(find.byKey(ValueKey('folder-$id')));
      await t.pumpAndSettle();
      await openDissolution(t, 'Trip');
      await org.rename(child, 'Renamed');
      await t.tap(find.text('确认解散'));
      await t.pumpAndSettle();
      expect(find.textContaining('解散预检已过期'), findsOneWidget);
      expect(org.snapshot.exists(id), true);
      await t.tap(find.byKey(ValueKey('folder-$child')));
      await t.pumpAndSettle();
      source.image = () async => base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
      );
      await t.tap(find.widgetWithText(AlbumTreeRow, 'A'));
      await t.pumpAndSettle();
      await t.tap(find.byType(PhotoTile).last);
      await t.pumpAndSettle();
      expect(find.byType(PhotoViewer), findsOneWidget);
      expect(await org.dissolve(org.previewDissolution(id)), isNull);
      await t.pumpAndSettle();
      expect(find.byType(PhotoViewer), findsOneWidget);
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(
        t.widget<PhotoGrid>(find.byType(PhotoGrid)).position!.anchor,
        source.items.single.key,
      );
      await t.tap(find.byKey(const ValueKey('album-panel-toggle')));
      await t.pumpAndSettle();
      expect(find.text('Trip'), findsNothing);
      expect(find.text('Renamed'), findsOneWidget);
      expect(find.widgetWithText(AlbumTreeRow, 'A'), findsOneWidget);
    },
  );

  testWidgets(
    'dialog validation, cancel, double save and disposed dialog do not duplicate or reopen',
    (t) async {
      await initialize();
      await show(t);
      await t.tap(find.byTooltip('新建'));
      await t.pumpAndSettle();
      await t.tap(find.text('相册文件夹'));
      await t.pumpAndSettle();
      await t.tap(find.text('保存'));
      await t.pumpAndSettle();
      expect(find.text('名称须为 1–64 个字符'), findsOneWidget);
      await t.enterText(find.byType(TextField), 'Trip');
      store.pending = Completer<void>();
      await t.tap(find.text('保存'));
      await t.pump();
      expect(org.snapshot.folders, isEmpty);
      expect(find.text('保存中…'), findsOneWidget);
      await t.tap(find.text('取消'));
      await t.pump(const Duration(milliseconds: 400));
      store.pending!.complete();
      await t.pumpAndSettle();
      expect(org.snapshot.folders.length, 1);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.widgetWithText(AlbumTreeRow, 'Trip'), findsOneWidget);
    },
  );
  testWidgets(
    'twenty-album sidebar preserves selection and grid across ten simulated keyboard cancellations',
    (t) async {
      await initialize();
      source.items = [
        for (var i = 1; i <= 100; i++) photo(i),
        for (var i = 1; i < 20; i++)
          photo(100 + i, directory: 'Pictures/Other$i/'),
      ];
      await browser.refresh();
      await show(t);
      await t.tap(find.widgetWithText(AlbumTreeRow, 'A'));
      await t.pumpAndSettle();
      await t.drag(find.byType(PhotoGrid), const Offset(0, -400));
      await t.pumpAndSettle();
      final gridScroll = find.descendant(
        of: find.byType(PhotoGrid),
        matching: find.byType(Scrollable),
      );
      final offset = t.state<ScrollableState>(gridScroll).position.pixels;
      expect(offset, greaterThan(0));
      final generation = browser.generation;
      final photos = browser.photos;
      final writes = store.writes;
      await t.tap(find.byKey(const ValueKey('album-panel-toggle')));
      await t.pumpAndSettle();
      addTearDown(t.view.resetViewInsets);
      for (var i = 0; i < 10; i++) {
        await t.tap(find.byTooltip('新建'));
        await t.pumpAndSettle();
        await t.tap(find.text('相册文件夹'));
        await t.pumpAndSettle();
        // Layout/state regression only: this does not render or measure an IME.
        t.view.viewInsets = FakeViewPadding(
          bottom: 240 * t.view.devicePixelRatio,
        );
        await t.pumpAndSettle();
        await t.enterText(find.byType(TextField), 'Cancelled $i');
        await t.tap(find.text('取消'));
        await t.pumpAndSettle();
        t.view.resetViewInsets();
        await t.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(t.takeException(), isNull);
        expect(org.snapshot.folders, isEmpty);
        expect(store.writes, writes);
        expect(browser.generation, generation);
        expect(browser.photos, same(photos));
      }
      await t.tap(find.byKey(const ValueKey('sidebar-close')));
      await t.pumpAndSettle();
      expect(
        t.widget<PhotoGrid>(find.byType(PhotoGrid)).albumKey,
        source.items.first.albumKey,
      );
      expect(
        t.state<ScrollableState>(gridScroll).position.pixels,
        closeTo(offset, 1),
      );
    },
  );
  testWidgets(
    'permission denial and query failure retain browsable private folders and unknown counts',
    (t) async {
      await initialize();
      await org.create(rootFolder, 'Trip');
      final id = org.snapshot.folders.keys.single;
      await org.moveAlbum(
        source.items.single.albumKey,
        id,
        generation: browser.generation,
      );
      await show(t);
      source.access = PhotoAccess.denied;
      await browser.refresh();
      await t.pumpAndSettle();
      expect(find.textContaining('媒体权限已拒绝'), findsOneWidget);
      expect(find.textContaining('1 个暂不可见'), findsOneWidget);
      await t.tap(find.widgetWithText(AlbumTreeRow, 'Trip'));
      await t.pumpAndSettle();
      expect(find.text('此处暂无可访问相册'), findsOneWidget);
      source.access = PhotoAccess.full;
      source.query = (_) => throw StateError('failed');
      await browser.refresh();
      await t.pumpAndSettle();
      expect(find.textContaining('媒体查询失败'), findsOneWidget);
      expect(find.textContaining('张可访问照片'), findsNothing);
      source.query = null;
      await browser.refresh();
      await t.pumpAndSettle();
      expect(find.widgetWithText(AlbumTreeRow, 'A'), findsOneWidget);
    },
  );
  testWidgets(
    'expanded tree follows moved folder and removal without stale nodes',
    (t) async {
      await initialize();
      await org.create(rootFolder, 'A');
      final a = org.snapshot.folders.keys.single;
      await org.create(a, 'B');
      final b = org.snapshot.children(a).single.id;
      await org.create(rootFolder, 'Other');
      final other = org.snapshot
          .children(rootFolder)
          .singleWhere((f) => f.name == 'Other')
          .id;
      await show(t);
      await t.tap(find.byKey(ValueKey('folder-$a')));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(AlbumTreeRow, 'B'));
      await t.pumpAndSettle();
      await org.moveFolder(b, other);
      await t.pumpAndSettle();
      expect(find.byKey(ValueKey('folder-$b')), findsNothing);
      await t.tap(find.byKey(ValueKey('folder-$other')));
      await t.pumpAndSettle();
      expect(find.byKey(ValueKey('folder-$b')), findsOneWidget);
      await org.deleteEmpty(b);
      await t.pumpAndSettle();
      expect(find.text('Other'), findsOneWidget);
      expect(find.byKey(ValueKey('folder-$b')), findsNothing);
    },
  );
  testWidgets(
    'failed organization never appears empty and retry recovers original tree',
    (t) async {
      await initialize();
      await org.create(rootFolder, 'Trip');
      store.failRead = true;
      await org.load();
      await show(t);
      expect(find.textContaining('组织数据加载失败'), findsOneWidget);
      expect(find.text('此相册文件夹为空'), findsNothing);
      store.failRead = false;
      await t.tap(find.text('重试加载'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('album-panel-toggle')));
      await t.pumpAndSettle();
      expect(find.widgetWithText(AlbumTreeRow, 'Trip'), findsOneWidget);
    },
  );
  testWidgets(
    'management tree restores scroll offset after collapse and reopen',
    (t) async {
      await initialize();
      for (var i = 0; i < 25; i++) {
        await org.create(rootFolder, 'Folder ${i.toString().padLeft(2, '0')}');
      }
      await show(t);
      await t.drag(
        find.byKey(const ValueKey('album-management-list')),
        const Offset(0, -900),
      );
      await t.pumpAndSettle();
      final before = t
          .state<ScrollableState>(
            find.descendant(
              of: find.byKey(const ValueKey('album-management-list')),
              matching: find.byType(Scrollable),
            ),
          )
          .position
          .pixels;
      final tile = find.widgetWithText(AlbumTreeRow, 'Folder 16');
      await t.ensureVisible(tile);
      await t.pumpAndSettle();
      final anchor = t.getTopLeft(tile).dy;
      await t.tap(tile);
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('sidebar-close')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('album-panel-toggle')));
      await t.pumpAndSettle();
      expect(before, greaterThan(0));
      expect(t.getTopLeft(tile).dy, closeTo(anchor, 1));
    },
  );
  testWidgets(
    '012 draft cancel, boundary arrows, failed save retry and stale media hide albums',
    (t) async {
      await initialize();
      await org.create(rootFolder, 'A');
      await org.create(rootFolder, 'B');
      final before = org.snapshot;
      await showLegacyOrder(t);
      await t.tap(find.byTooltip('调整 A').first);
      await t.pumpAndSettle();
      expect(
        t
            .widget<PopupMenuItem<int>>(
              find.widgetWithText(PopupMenuItem<int>, '上移'),
            )
            .enabled,
        isFalse,
      );
      await t.tap(find.text('下移'));
      await t.pumpAndSettle();
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(org.snapshot, same(before));
      await t.tap(find.text('Open legacy order regression'));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('调整 A').first);
      await t.pumpAndSettle();
      await t.tap(find.text('下移'));
      await t.pumpAndSettle();
      store.failWrite = true;
      await t.tap(find.text('保存'));
      await t.pumpAndSettle();
      expect(find.textContaining('保存失败'), findsOneWidget);
      expect(org.snapshot, same(before));
      store.failWrite = false;
      store.pending = Completer<void>();
      await t.tap(find.text('保存'));
      await t.pump();
      expect(
        t.widget<TextButton>(find.widgetWithText(TextButton, '取消')).onPressed,
        isNull,
      );
      await t.binding.handlePopRoute();
      await t.pump();
      expect(find.text('保存中…'), findsOneWidget);
      store.pending!.complete();
      await t.pumpAndSettle();
      expect(find.text('调整顺序'), findsNothing);
      expect(org.snapshot.children(rootFolder).map((f) => f.name), ['B', 'A']);
      await t.tap(find.text('Open legacy order regression'));
      await t.pumpAndSettle();
      source.access = PhotoAccess.denied;
      await browser.refresh();
      await t.pumpAndSettle();
      expect(find.textContaining('草稿已过期'), findsOneWidget);
      expect(find.text('相册'), findsNothing);
      expect(
        t.widget<TextButton>(find.widgetWithText(TextButton, '保存')).onPressed,
        isNull,
      );
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(org.snapshot.children(rootFolder).map((f) => f.name), ['B', 'A']);
    },
  );
  testWidgets(
    'same-name albums retain directory identity in order draft and only selected key moves',
    (t) async {
      await initialize();
      source.items = [
        photo(1, directory: 'Pictures/one/Same/'),
        photo(2, directory: 'Pictures/two/Same/'),
      ];
      await browser.refresh();
      await showLegacyOrder(t);
      for (final p in source.items) {
        expect(find.text(p.albumKey), findsNothing);
        expect(
          find.text(p.directory.contains('one') ? 'one/Same' : 'two/Same'),
          findsOneWidget,
        );
      }
      final first = find.byKey(
        ValueKey('order-${source.items.first.albumKey}'),
      );
      await t.tap(
        find.descendant(of: first, matching: find.byTooltip('调整 Same')),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('下移'));
      await t.pumpAndSettle();
      await t.tap(find.text('保存'));
      await t.pumpAndSettle();
      expect(
        org.snapshot.albumOrders[rootFolder],
        source.items.reversed.map((p) => p.albumKey),
      );
    },
  );
}
