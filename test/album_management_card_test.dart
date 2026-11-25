import 'package:phototree/ui/album_tree_row.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/media/browser.dart';
import 'package:phototree/media/media_source.dart';
import 'package:phototree/organization/organization.dart';
import 'package:phototree/ui/photo_grid.dart';

import 'package:phototree/ui/library_shell.dart';
import 'package:phototree/ui/photo_viewer.dart';
import 'package:phototree/ui/visual_style.dart';

import 'media_browser_test.dart' show FakeMedia, photo;
import 'organization_test.dart' show MemoryOrganization;

class _DelayedStore extends MemoryOrganization {
  Completer<void>? readGate;

  @override
  Future<OrganizationSnapshot> read() async {
    await readGate?.future;
    return super.read();
  }
}

void main() {
  late FakeMedia source;
  late PhotoBrowser browser;
  late MemoryOrganization store;
  late Organization org;

  Future<void> setup(WidgetTester t, {int albums = 2}) async {
    source = FakeMedia()
      ..items = List.generate(
        albums,
        (i) => photo(
          i + 1,
          directory: 'Pictures/Album${i.toString().padLeft(2, '0')}/',
        ),
      );
    source.image = () async => base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jw1kAAAAASUVORK5CYII=',
    );
    browser = PhotoBrowser(source);
    await browser.refresh();
    store = _DelayedStore();
    org = Organization(store, browser);
    await org.load();
    t.view.physicalSize = const Size(420, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
  }

  Future<void> show(WidgetTester t, {bool reduceMotion = false}) async {
    await t.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(disableAnimations: reduceMotion),
          child: child!,
        ),
        home: LibraryShell(organization: org, browser: browser),
      ),
    );
    await t.pumpAndSettle();
  }

  Future<void> toggle(WidgetTester t) async {
    await t.tap(
      find.byKey(
        ValueKey(
          find.byKey(const ValueKey('sidebar-close')).evaluate().isNotEmpty
              ? 'sidebar-close'
              : 'album-panel-toggle',
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  Future<TestGesture> start(WidgetTester t, String key) async {
    final g = await t.startGesture(
      t.getCenter(
        find.byWidgetPredicate(
          (w) => w is AlbumTreeRow && w.key == ValueKey(key),
        ),
      ),
    );
    await t.pump(const Duration(milliseconds: 600));
    return g;
  }

  Future<void> drop(WidgetTester t, String sourceKey, String targetKey) async {
    final g = await start(t, sourceKey);
    await g.moveTo(t.getCenter(find.byKey(ValueKey(targetKey))));
    await t.pump(const Duration(milliseconds: 100));
    await g.up();
    await t.pumpAndSettle();
  }

  tearDown(() {
    org.dispose();
    browser.dispose();
  });

  testWidgets('sidebar distinguishes loading and failure and retries', (
    t,
  ) async {
    await setup(t);
    await show(t);
    await toggle(t);
    final delayed = store as _DelayedStore;
    delayed.readGate = Completer<void>();
    delayed.failRead = true;
    final loading = org.load();
    await t.pump();
    expect(find.text('正在加载相册分类…'), findsOneWidget);
    final retry = find.descendant(
      of: find.byKey(const ValueKey('album-management-panel')),
      matching: find.widgetWithText(TextButton, '重试加载'),
    );
    expect(t.widget<TextButton>(retry).onPressed, isNull);
    delayed.readGate!.complete();
    await loading;
    await t.pumpAndSettle();
    expect(find.text('相册分类暂时无法加载，原有分类已保留'), findsOneWidget);
    delayed.failRead = false;
    await t.tap(retry);
    await t.pumpAndSettle();
    expect(find.byKey(ValueKey(source.items.first.albumKey)), findsOneWidget);
  });

  testWidgets(
    'folder and album labels align at each depth without shrinking menus',
    (t) async {
      await setup(t);
      source.items.addAll(
        List.generate(12, (i) => photo(10 + i, directory: 'Pictures/Album01/')),
      );
      await browser.refresh();
      const parentName = '很长的中文文件夹名用于核对窄屏文字';
      await org.create(rootFolder, parentName);
      final parent = org.snapshot.children(rootFolder).single.id;
      await org.create(parent, 'Nested folder with a long name');
      final nested = org.snapshot.children(parent).single.id;
      final first = source.items.first.albumKey;
      final last = source.items[1].albumKey;
      await org.moveAlbum(last, parent, generation: browser.generation);
      await show(t);
      await toggle(t);
      Finder row(String key) => find.byKey(ValueKey(key));
      double labelX(String key) => t
          .getTopLeft(
            find.descendant(of: row(key), matching: find.byType(Text)).first,
          )
          .dx;
      void checkPair(String folder, String album) {
        final key = 'folder-$folder';
        final icon = find.descendant(
          of: row(key),
          matching: find.byIcon(Icons.folder_outlined),
        );
        expect(labelX(key) - t.getTopRight(icon).dx, 4);
        expect(labelX(key), labelX(album));
        for (final id in [key, album]) {
          final menu = find.descendant(
            of: row(id),
            matching: find.byType(PopupMenuButton<String>),
          );
          final size = t.getSize(menu);
          expect(size.width, greaterThanOrEqualTo(48));
          expect(size.height, greaterThanOrEqualTo(48));
          expect(
            t.getSize(
              find.descendant(of: menu, matching: find.byIcon(Icons.more_vert)),
            ),
            const Size.square(20),
          );
        }
      }

      checkPair(parent, first);
      await t.tap(row('folder-$parent'));
      await t.pumpAndSettle();
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
      for (final width in [420.0, 320.0]) {
        for (final scale in [1.0, 2.0]) {
          t.view.physicalSize = Size(width, 1200);
          t.platformDispatcher.textScaleFactorTestValue = scale;
          await t.pumpAndSettle();
          checkPair(parent, first);
          checkPair(nested, last);
          final count = find.descendant(
            of: row(last),
            matching: find.text('13'),
          );
          expect(
            t.getRect(count).left,
            greaterThanOrEqualTo(
              t
                  .getRect(
                    find
                        .descendant(of: row(last), matching: find.byType(Text))
                        .first,
                  )
                  .right,
            ),
          );
          expect(labelX('folder-$nested') - labelX('folder-$parent'), 14);
          expect(t.takeException(), isNull);
        }
      }
      await t.tap(row('folder-$parent'));
      await t.pumpAndSettle();
      checkPair(parent, first);
      expect(row('folder-$nested'), findsNothing);
    },
  );

  testWidgets(
    'selection drives photo body; panel toggles never rescan and barrier closes only panel',
    (t) async {
      await setup(t);
      await show(t);
      final generation = browser.generation;
      expect(t.widget<PhotoGrid>(find.byType(PhotoGrid)).albumKey, isNull);
      await toggle(t);
      final a = source.items.first.albumKey, b = source.items.last.albumKey;
      await t.tap(find.byKey(ValueKey(a)));
      await t.pumpAndSettle();
      expect(t.widget<PhotoGrid>(find.byType(PhotoGrid)).albumKey, a);
      expect(find.byKey(const ValueKey('album-panel-scrim')), findsNothing);
      await toggle(t);
      await t.tap(find.byKey(ValueKey(b)));
      await t.pumpAndSettle();
      expect(t.widget<PhotoGrid>(find.byType(PhotoGrid)).albumKey, b);
      await toggle(t);
      await t.tapAt(const Offset(400, 850));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('album-panel-scrim')), findsNothing);
      expect(t.widget<PhotoGrid>(find.byType(PhotoGrid)).albumKey, b);
      expect(browser.generation, generation);
      expect(t.widget<PhotoGrid>(find.byType(PhotoGrid)).position, isNotNull);
    },
  );

  testWidgets(
    'actual album drop saves once, selected body stays; expanded folder can return album to root',
    (t) async {
      await setup(t);
      await org.create(rootFolder, 'Trip');
      final folder = org.snapshot.children(rootFolder).single.id;
      final album = source.items.first.albumKey;
      await show(t);
      await toggle(t);
      await t.tap(find.byKey(ValueKey(album)));
      await t.pumpAndSettle();
      await toggle(t);
      final writes = store.writes;
      final photos = List<Photo>.of(browser.photos);
      await drop(t, album, 'drop-$folder');
      expect(org.snapshot.parentOfAlbum(album), folder);
      expect(store.writes, writes + 1);
      expect(t.widget<PhotoGrid>(find.byType(PhotoGrid)).albumKey, album);
      expect(browser.photos, photos);
      await t.tap(find.byKey(ValueKey('folder-$folder')));
      await t.pumpAndSettle();
      await drop(t, album, 'drop-$rootFolder');
      expect(org.snapshot.parentOfAlbum(album), rootFolder);
      expect(store.writes, writes + 2);
      await org.load();
      expect(org.snapshot.parentOfAlbum(album), rootFolder);
    },
  );

  testWidgets(
    'insertion drop changes same-level order immediately and survives reload',
    (t) async {
      await setup(t);
      await show(t);
      await toggle(t);
      final a = source.items.first.albumKey, b = source.items.last.albumKey;
      final writes = store.writes;
      await drop(t, b, 'insert-$rootFolder-album-0');
      expect(org.snapshot.albums(rootFolder, org.albums).map((a) => a.key), [
        b,
        a,
      ]);
      expect(store.writes, writes + 1);
      await org.load();
      expect(org.snapshot.albums(rootFolder, org.albums).map((a) => a.key), [
        b,
        a,
      ]);
    },
  );

  testWidgets(
    'cancel, save failure and revoked permission cannot commit a drag',
    (t) async {
      await setup(t);
      await org.create(rootFolder, 'Trip');
      final folder = org.snapshot.children(rootFolder).single.id;
      final album = source.items.first.albumKey;
      await show(t);
      await toggle(t);
      final writes = store.writes;
      var gesture = await start(t, album);
      await gesture.moveTo(const Offset(410, 850));
      await gesture.cancel();
      await t.pumpAndSettle();
      expect(store.writes, writes);
      store.failWrite = true;
      await drop(t, album, 'drop-$folder');
      expect(org.snapshot.parentOfAlbum(album), rootFolder);
      expect(store.data.parentOfAlbum(album), rootFolder);
      store.failWrite = false;
      gesture = await start(t, album);
      source.access = PhotoAccess.denied;
      await browser.refresh();
      await t.pump();
      final afterRevoke = store.writes;
      await gesture.moveTo(t.getCenter(find.byKey(ValueKey('drop-$folder'))));
      await gesture.up();
      await t.pumpAndSettle();
      expect(store.writes, afterRevoke);
      expect(org.snapshot.parentOfAlbum(album), rootFolder);
      expect(find.byKey(ValueKey(album)), findsNothing);
    },
  );

  testWidgets(
    'open folder menu rejects creation when its folder was removed externally',
    (t) async {
      await setup(t);
      await org.create(rootFolder, 'Trip');
      final folder = org.snapshot.children(rootFolder).single.id;
      await show(t);
      await toggle(t);
      await t.tap(find.byTooltip('管理 Trip'));
      await t.pumpAndSettle();
      expect(find.text('在此新建相册文件夹'), findsOneWidget);
      expect(await org.deleteEmpty(folder), isNull);
      await t.pump();
      final writes = store.writes;
      await t.tap(find.text('在此新建相册文件夹'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      // The removed row disposes its popup owner, so Flutter drops the callback.
      expect(find.byType(AlertDialog), findsNothing);
      expect(store.writes, writes);
      expect(org.snapshot.folders, isEmpty);
    },
  );

  testWidgets('open menu rejects a changed tree even when its row survives', (
    t,
  ) async {
    await setup(t);
    await org.create(rootFolder, 'Trip');
    await show(t);
    await toggle(t);
    await t.tap(find.byTooltip('管理 Trip'));
    await t.pumpAndSettle();
    await org.create(rootFolder, 'Work');
    await t.pump();
    final writes = store.writes;
    await t.tap(find.text('在此新建相册文件夹'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.text('相册或分类已变化，请重新操作'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(store.writes, writes);
  });

  testWidgets('landscape card expands and collapses without overflow', (
    t,
  ) async {
    await setup(t);
    t.view.physicalSize = const Size(900, 420);
    await show(t);
    expect(t.takeException(), isNull);
    await toggle(t);
    expect(find.byKey(const ValueKey('album-management-list')), findsOneWidget);
    expect(t.takeException(), isNull);
    await toggle(t);
    expect(find.byKey(const ValueKey('album-panel-scrim')), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'stationary pointer cannot commit the old insertion target after edge scrolling',
    (t) async {
      await setup(t, albums: 40);
      await show(t);
      await toggle(t);
      final list = find.byKey(const ValueKey('album-management-list'));
      final controller = t.widget<ListView>(list).controller!;
      controller.jumpTo(200);
      await t.pump();
      final gesture = await start(t, source.items[3].albumKey);
      final bounds = t.getRect(list);
      final target = find.byKey(ValueKey('insert-$rootFolder-album-6'));
      // Align a real, non-no-op insertion target inside the bottom edge zone.
      // The pointer has not entered it yet, so the setup scroll cannot create
      // a false positive by invalidating an already accepted target.
      final targetY = t.getCenter(target).dy;
      controller.jumpTo(controller.offset + targetY - (bounds.bottom - 20));
      await t.pump();
      final point = t.getCenter(target);
      expect(bounds.contains(point), isTrue);
      expect(point.dy, greaterThan(bounds.bottom - 44));
      await gesture.moveTo(point);
      await t.pump();
      final line = find.descendant(
        of: target,
        matching: find.byType(Container),
      );
      expect(
        t.widget<Container>(line).color,
        Theme.of(t.element(target)).colorScheme.primary,
        reason: 'The insertion must be accepted before automatic scrolling',
      );
      final offset = controller.offset;
      final writes = store.writes;
      final order = org.snapshot
          .albums(rootFolder, org.albums)
          .map((a) => a.key)
          .toList();
      await t.pump(const Duration(milliseconds: 800));
      expect(controller.offset, greaterThan(offset));
      // Deliberately no move event: releasing here must not apply the former
      // target merely because DragTarget still remembers its candidate.
      await gesture.up();
      await t.pumpAndSettle();
      expect(store.writes, writes);
      expect(
        org.snapshot.albums(rootFolder, org.albums).map((a) => a.key),
        order,
      );
    },
  );

  testWidgets(
    'drag near card edge scrolls the tree without committing on cancel',
    (t) async {
      await setup(t, albums: 40);
      await show(t);
      await toggle(t);
      final list = find.byKey(const ValueKey('album-management-list'));
      final controller = t.widget<ListView>(list).controller!;
      final writes = store.writes;
      final gesture = await start(t, source.items.first.albumKey);
      final bounds = t.getRect(list);
      await gesture.moveTo(Offset(bounds.center.dx, bounds.bottom - 5));
      await t.pump(const Duration(milliseconds: 800));
      expect(controller.offset, greaterThan(0));
      await gesture.cancel();
      await t.pumpAndSettle();
      expect(store.writes, writes);
    },
  );
  testWidgets('edge scroll advances on each frame with twenty albums', (
    t,
  ) async {
    await setup(t, albums: 20);
    await show(t);
    await toggle(t);
    final list = find.byKey(const ValueKey('album-management-list'));
    final controller = t.widget<ListView>(list).controller!;
    final gesture = await start(t, source.items.first.albumKey);
    final bounds = t.getRect(list);
    await gesture.moveTo(Offset(bounds.center.dx, bounds.bottom - 5));
    await t.pump(const Duration(milliseconds: 48));
    final offsets = <double>[controller.offset];
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 16));
      offsets.add(controller.offset);
    }
    await gesture.cancel();
    await t.pumpAndSettle();
    expect(
      List.generate(8, (i) => offsets[i + 1] > offsets[i]),
      everyElement(isTrue),
      reason: 'frame offsets: $offsets',
    );
  });

  for (final bottom in [false, true]) {
    testWidgets(
      'leaving the tree ${bottom ? 'bottom' : 'top'} stops edge scroll until reentry',
      (t) async {
        await setup(t, albums: 40);
        await show(t);
        await toggle(t);
        final list = find.byKey(const ValueKey('album-management-list'));
        final controller = t.widget<ListView>(list).controller!;
        controller.jumpTo(200);
        await t.pump();
        final gesture = await start(t, source.items[3].albumKey);
        final bounds = t.getRect(list);
        final writes = store.writes;
        await gesture.moveTo(
          Offset(
            bounds.center.dx,
            bottom ? bounds.bottom + 20 : bounds.top - 20,
          ),
        );
        await t.pump();
        final outsideOffset = controller.offset;
        for (var i = 0; i < 10; i++) {
          await t.pump(const Duration(milliseconds: 16));
        }
        expect(controller.offset, outsideOffset);
        await gesture.moveTo(
          Offset(bounds.center.dx, bottom ? bounds.bottom - 5 : bounds.top + 5),
        );
        for (var i = 0; i < 5; i++) {
          await t.pump(const Duration(milliseconds: 16));
        }
        expect(
          controller.offset,
          bottom ? greaterThan(outsideOffset) : lessThan(outsideOffset),
        );
        await gesture.cancel();
        await t.pumpAndSettle();
        expect(store.writes, writes);
        expect(t.takeException(), isNull);
      },
    );
  }

  for (final direction in [-1, 0, 1]) {
    testWidgets(
      'short tree edge scroll direction $direction has no overlapping zones',
      (t) async {
        await setup(t, albums: 40);
        t.view.physicalSize = const Size(800, 320);
        await t.pumpWidget(
          MaterialApp(
            theme: photoTreeTheme(Brightness.light),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2),
                padding: const EdgeInsets.all(24),
              ),
              child: child!,
            ),
            home: LibraryShell(organization: org, browser: browser),
          ),
        );
        await t.pumpAndSettle();
        await t.tap(find.byTooltip('更多'));
        await t.pumpAndSettle();
        await t.ensureVisible(find.text('侧栏外观'));
        await t.pumpAndSettle();
        await t.tap(find.text('侧栏外观'));
        await t.pumpAndSettle();
        final list = find.byKey(const ValueKey('album-management-list'));
        final scrollable = find.descendant(
          of: list,
          matching: find.byType(Scrollable),
        );
        final row = find.byKey(ValueKey(source.items[3].albumKey));
        await t.scrollUntilVisible(row, 50, scrollable: scrollable);
        await t.pumpAndSettle();
        final controller = t.widget<ListView>(list).controller!;
        final bounds = t.getRect(list);
        expect(bounds.height, lessThan(88));
        controller.jumpTo(
          controller.offset + t.getCenter(row).dy - bounds.center.dy,
        );
        await t.pumpAndSettle();
        final sourcePoint = t.getCenter(row);
        expect(
          bounds.contains(sourcePoint),
          isTrue,
          reason: 'source=$sourcePoint, viewport=$bounds',
        );
        final gesture = await t.startGesture(sourcePoint);
        await t.pump(const Duration(milliseconds: 600));
        expect(
          find.byWidgetPredicate((w) => w is Material && w.elevation == 8),
          findsOneWidget,
          reason: 'A real drag must start before measuring edge direction',
        );
        final y = direction < 0
            ? bounds.top + 10
            : direction > 0
            ? bounds.bottom - 10
            : bounds.center.dy;
        await gesture.moveTo(Offset(bounds.center.dx, y));
        await t.pump();
        final before = controller.offset;
        final writes = store.writes;
        for (var i = 0; i < 5; i++) {
          await t.pump(const Duration(milliseconds: 16));
        }
        final after = controller.offset;
        await gesture.cancel();
        await t.pumpAndSettle();
        expect(
          after,
          direction < 0
              ? lessThan(before)
              : direction > 0
              ? greaterThan(before)
              : before,
          reason: 'viewport=$bounds, pointerY=$y, offsets=$before -> $after',
        );
        expect(store.writes, writes);
        expect(t.takeException(), isNull);
      },
    );
  }

  testWidgets('folder hover does not change destination height', (t) async {
    await setup(t, albums: 20);
    await org.create(rootFolder, 'Trip');
    final folder = org.snapshot.children(rootFolder).single.id;
    await show(t);
    await toggle(t);
    final target = find.byKey(ValueKey('drop-$folder'));
    final height = t.getSize(target).height;
    final gesture = await start(t, source.items.first.albumKey);
    await gesture.moveTo(t.getCenter(target));
    await t.pump();
    final hoveredHeight = t.getSize(target).height;
    await gesture.cancel();
    await t.pumpAndSettle();
    expect(hoveredHeight, height);
  });

  testWidgets(
    'sidebar slides from left and reverses without moving photo body',
    (t) async {
      await setup(t);
      await show(t);
      await toggle(t);
      await t.tap(find.byKey(ValueKey(source.items.first.albumKey)));
      await t.pumpAndSettle();
      final grid = t.getRect(find.byType(PhotoGrid));
      await t.tap(find.byKey(const ValueKey('album-panel-toggle')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 40));
      final panel = find.byKey(const ValueKey('album-management-panel'));
      final midway = t.getRect(panel);
      expect(midway.left, lessThan(0));
      expect(midway.width, closeTo(grid.width * .74, .01));
      expect(t.getRect(find.byType(PhotoGrid)), grid);
      t
          .widget<IconButton>(find.byKey(const ValueKey('sidebar-close')))
          .onPressed!();
      await t.pump();
      expect(t.getRect(panel).left, closeTo(midway.left, .001));
      await t.pump(const Duration(milliseconds: 20));
      expect(t.getRect(panel).left, lessThan(midway.left));
      await t.pumpAndSettle();
      expect(panel, findsNothing);
      expect(t.getRect(find.byType(PhotoGrid)), grid);
      await toggle(t);
      await t.drag(
        find.byKey(const ValueKey('album-management-panel')),
        const Offset(-180, 0),
      );
      await t.pumpAndSettle();
      expect(panel, findsNothing);
    },
  );

  testWidgets('reduced motion opens immediately with compact accessible rows', (
    t,
  ) async {
    await setup(t);
    await show(t, reduceMotion: true);
    await t.tap(find.byKey(const ValueKey('album-panel-toggle')));
    await t.pump();
    final panel = find.byKey(const ValueKey('album-management-panel'));
    expect(t.getRect(panel).left, 0);
    final row = find.byWidgetPredicate(
      (w) =>
          w is AlbumTreeRow && w.key == ValueKey(source.items.first.albumKey),
    );
    expect(t.getSize(row).height, greaterThanOrEqualTo(48));
    final theme = ListTileTheme.of(t.element(row));
    expect(theme.titleTextStyle!.fontSize, 16);
    expect(theme.subtitleTextStyle!.fontSize, 12);
    expect(
      theme.titleTextStyle!.color,
      Theme.of(t.element(row)).colorScheme.onSurface,
    );
    expect(
      theme.subtitleTextStyle!.color,
      Theme.of(t.element(row)).colorScheme.onSurfaceVariant,
    );
    await t.tap(find.byKey(const ValueKey('sidebar-close')));
    await t.pump();
    expect(panel, findsNothing);
  });
  testWidgets(
    'production shell keeps sidebar geometry during keyboard insets',
    (t) async {
      await setup(t, albums: 20);
      await t.pumpWidget(
        MaterialApp(
          home: LibraryShell(browser: browser, organization: org),
        ),
      );
      await t.pumpAndSettle();
      await toggle(t);
      final panel = find.byKey(const ValueKey('album-management-panel'));
      final before = t.getRect(panel);
      await t.tap(find.byTooltip('新建'));
      await t.pumpAndSettle();
      await t.tap(find.text('相册文件夹'));
      await t.pumpAndSettle();
      addTearDown(t.view.resetViewInsets);
      t.view.viewInsets = const FakeViewPadding(bottom: 280);
      await t.pumpAndSettle();
      final after = t.getRect(panel);
      expect(t.getRect(find.byType(TextField)).bottom, lessThan(620));
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      t.view.resetViewInsets();
      await t.pumpAndSettle();
      expect(after, before);
    },
  );

  testWidgets('closing sidebar still blocks background photo taps', (t) async {
    await setup(t);
    await show(t);
    await toggle(t);
    await t.tap(find.byKey(ValueKey(source.items.first.albumKey)));
    await t.pumpAndSettle();
    final tile = t.getCenter(find.byType(PhotoTile).first);
    await toggle(t);
    await t.tap(find.byKey(const ValueKey('sidebar-close')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 60));
    await t.tapAt(tile);
    await t.pumpAndSettle();
    expect(find.byType(PhotoViewer), findsNothing);
  });
}
