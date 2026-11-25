import 'package:phototree/ui/library_shell.dart';

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/media/browser.dart';
import 'package:phototree/organization/organization.dart';

import 'package:phototree/ui/photo_grid.dart';

import 'media_browser_test.dart' show FakeMedia, photo;
import 'organization_test.dart' show MemoryOrganization;

void main() {
  for (final expanded in [false, true]) {
    testWidgets(
      'folder insertion drag persists same-level order (expanded=$expanded)',
      (t) async {
        final browser = PhotoBrowser(FakeMedia());
        await browser.refresh();
        final store = MemoryOrganization();
        final org = Organization(store, browser);
        await org.load();
        await org.create(rootFolder, 'A');
        await org.create(rootFolder, 'B');
        final a = org.snapshot.children(rootFolder)[0].id;
        final b = org.snapshot.children(rootFolder)[1].id;
        await org.create(a, 'Child A');
        final child = org.snapshot.children(a).single.id;
        t.view.physicalSize = const Size(420, 900);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        addTearDown(org.dispose);
        addTearDown(browser.dispose);
        await t.pumpWidget(
          MaterialApp(
            home: LibraryShell(organization: org, browser: browser),
          ),
        );
        await t.pumpAndSettle();
        await t.tap(find.byKey(const ValueKey('album-panel-toggle')));
        await t.pumpAndSettle();
        if (expanded) {
          await t.tap(find.byKey(ValueKey('folder-$a')));
          await t.pumpAndSettle();
          expect(find.byKey(ValueKey('folder-$child')), findsOneWidget);
        }
        final writes = store.writes;
        final g = await t.startGesture(
          t.getCenter(find.byKey(ValueKey('folder-$b'))),
        );
        await t.pump(const Duration(milliseconds: 600));
        await g.moveTo(
          t.getCenter(find.byKey(ValueKey('insert-$rootFolder-folder-0'))),
        );
        await t.pump(const Duration(milliseconds: 100));
        await g.up();
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        expect(org.snapshot.children(rootFolder).map((f) => f.id), [b, a]);
        expect(org.snapshot.children(a).single.id, child);
        expect(store.writes, writes + 1);
        await org.load();
        expect(org.snapshot.children(rootFolder).map((f) => f.id), [b, a]);
      },
    );
  }

  group('folder cross-parent drops', () {
    late FakeMedia source;
    late PhotoBrowser browser;
    late MemoryOrganization store;
    late Organization org;

    Future<String> folder(String parent, String name) async {
      expect(await org.create(parent, name), isNull);
      return org.snapshot
          .children(parent)
          .singleWhere((f) => f.name == name)
          .id;
    }

    Future<void> mount(WidgetTester t) async {
      t.view.physicalSize = const Size(420, 1200);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.pumpWidget(
        MaterialApp(
          home: LibraryShell(organization: org, browser: browser),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('album-panel-toggle')));
      await t.pumpAndSettle();
    }

    Future<void> expand(WidgetTester t, String id) async {
      await t.tap(find.byKey(ValueKey('folder-$id')));
      await t.pumpAndSettle();
    }

    Future<TestGesture> start(WidgetTester t, String id) async {
      final gesture = await t.startGesture(
        t.getCenter(find.byKey(ValueKey('folder-$id'))),
      );
      await t.pump(const Duration(milliseconds: 600));
      return gesture;
    }

    Future<void> drop(WidgetTester t, String id, String target) async {
      final gesture = await start(t, id);
      await gesture.moveTo(t.getCenter(find.byKey(ValueKey('drop-$target'))));
      await t.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    }

    Future<void> setup() async {
      source = FakeMedia()..items = [photo(1)];
      source.image = () async => base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jw1kAAAAASUVORK5CYII=',
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

    for (final finishInCenter in [true, false]) {
      testWidgets(
        'cross-parent edge to center then edge=$finishInCenter matches hint and commit',
        (t) async {
          await setup();
          final a = await folder(rootFolder, 'A');
          final b = await folder(rootFolder, 'B');
          final child = await folder(a, 'Child');
          await mount(t);
          await expand(t, a);
          final row = find.byKey(ValueKey('folder-$b'));
          final before = t.getRect(row);
          final writes = store.writes;
          final gesture = await start(t, child);
          expect(t.getRect(row), before);
          await gesture.moveTo(Offset(before.center.dx, before.top + 2));
          await t.pump(const Duration(milliseconds: 40));
          expect(find.text('移入此处'), findsNothing);
          await gesture.moveTo(before.center);
          await t.pump(const Duration(milliseconds: 40));
          expect(find.text('移入此处'), findsOneWidget);
          expect(t.getRect(row), before);
          if (!finishInCenter) {
            await gesture.moveTo(Offset(before.center.dx, before.top + 2));
            await t.pump(const Duration(milliseconds: 40));
            expect(find.text('移入此处'), findsNothing);
          }
          await gesture.up();
          await t.pumpAndSettle();
          expect(org.snapshot.folders[child]!.parent, finishInCenter ? b : a);
          expect(store.writes, writes + (finishInCenter ? 1 : 0));
          expect(t.takeException(), isNull);
        },
      );
    }

    testWidgets(
      'after expanded subtree insertion keeps descendants and geometry',
      (t) async {
        await setup();
        final b = await folder(rootFolder, 'B');
        final a = await folder(rootFolder, 'A');
        final child = await folder(a, 'Child');
        final leaf = await folder(child, 'Leaf');
        await mount(t);
        await expand(t, a);
        await expand(t, child);
        final before = {
          for (final id in [a, b, child, leaf])
            id: t.getRect(find.byKey(ValueKey('folder-$id'))),
        };
        final writes = store.writes;
        final gesture = await start(t, b);
        for (final id in before.keys) {
          expect(t.getRect(find.byKey(ValueKey('folder-$id'))), before[id]);
        }
        final boundary = t.getRect(
          find.byKey(ValueKey('insert-$rootFolder-folder-2')),
        );
        expect(boundary.bottom, before[leaf]!.bottom);
        expect(boundary.top, greaterThan(before[a]!.bottom));
        await gesture.moveTo(boundary.center);
        await t.pump(const Duration(milliseconds: 60));
        expect(find.text('移入此处'), findsNothing);
        await gesture.up();
        await t.pumpAndSettle();
        expect(org.snapshot.children(rootFolder).map((f) => f.id), [a, b]);
        expect(org.snapshot.folders[child]!.parent, a);
        expect(org.snapshot.folders[leaf]!.parent, child);
        expect(store.writes, writes + 1);
        await org.load();
        expect(org.snapshot.children(rootFolder).map((f) => f.id), [a, b]);
        expect(t.takeException(), isNull);
      },
    );

    testWidgets(
      'move subtree into another folder and root while selected grid survives',
      (t) async {
        await setup();
        final a = await folder(rootFolder, 'A');
        final b = await folder(rootFolder, 'B');
        final child = await folder(a, 'Child');
        final leaf = await folder(child, 'Leaf');
        final album = source.items.single.albumKey;
        expect(
          await org.moveAlbum(album, leaf, generation: browser.generation),
          isNull,
        );
        await mount(t);
        await expand(t, a);
        await expand(t, child);
        await expand(t, leaf);
        await t.tap(find.byKey(ValueKey(album)));
        await t.pumpAndSettle();
        final gridState = t.state(find.byType(PhotoGrid));
        final photos = [...browser.photos];
        final generation = browser.generation;
        await t.tap(find.byKey(const ValueKey('album-panel-toggle')));
        await t.pumpAndSettle();
        final writes = store.writes;
        await drop(t, a, b);
        expect(org.snapshot.folders[a]!.parent, b);
        expect(org.snapshot.children(b).map((f) => f.id), [a]);
        expect(org.snapshot.folders[child]!.parent, a);
        expect(org.snapshot.folders[leaf]!.parent, child);
        expect(org.snapshot.parentOfAlbum(album), leaf);
        expect(store.writes, writes + 1);
        expect(t.state(find.byType(PhotoGrid)), same(gridState));
        expect(t.widget<PhotoGrid>(find.byType(PhotoGrid)).albumKey, album);
        expect(browser.photos, photos);
        expect(browser.generation, generation);
        // The destination may already be expanded to reveal the moved subtree.
        if (find.byKey(ValueKey('folder-$a')).evaluate().isEmpty) {
          await expand(t, b);
        }
        await drop(t, a, rootFolder);
        expect(org.snapshot.folders[a]!.parent, rootFolder);
        expect(store.writes, writes + 2);
        expect(t.state(find.byType(PhotoGrid)), same(gridState));
        await org.load();
        expect(org.snapshot.folders[a]!.parent, rootFolder);
        expect(org.snapshot.folders[leaf]!.parent, child);
        expect(org.snapshot.parentOfAlbum(album), leaf);
      },
    );

    testWidgets('deep subtree can move to a visible ancestor', (t) async {
      await setup();
      final ancestor = await folder(rootFolder, 'Ancestor');
      final parent = await folder(ancestor, 'Parent');
      final a = await folder(parent, 'A');
      final child = await folder(a, 'Child');
      await mount(t);
      await expand(t, ancestor);
      await expand(t, parent);
      final writes = store.writes;
      await drop(t, a, ancestor);
      expect(org.snapshot.folders[a]!.parent, ancestor);
      expect(org.snapshot.folders[child]!.parent, a);
      expect(store.writes, writes + 1);
      await org.load();
      expect(org.snapshot.folders[a]!.parent, ancestor);
    });

    testWidgets('self descendant same-parent and outside drops never write', (
      t,
    ) async {
      await setup();
      final a = await folder(rootFolder, 'A');
      final child = await folder(a, 'Child');
      await mount(t);
      await expand(t, a);
      final before = org.snapshot;
      final writes = store.writes;
      for (final target in [a, child, rootFolder]) {
        final gesture = await start(t, a);
        await gesture.moveTo(t.getCenter(find.byKey(ValueKey('drop-$target'))));
        await t.pump(const Duration(milliseconds: 100));
        expect(find.text('移入此处'), findsNothing);
        await gesture.up();
        await t.pumpAndSettle();
        expect(store.writes, writes);
        expect(org.snapshot, same(before));
      }
      final gesture = await start(t, a);
      await gesture.moveTo(const Offset(410, 1100));
      await gesture.up();
      await t.pumpAndSettle();
      expect(store.writes, writes);
      expect(org.snapshot, same(before));
    });

    testWidgets(
      'failed persistence and duplicate target name preserve the complete tree',
      (t) async {
        await setup();
        final a = await folder(rootFolder, 'A');
        final b = await folder(rootFolder, 'B');
        final child = await folder(a, 'Child');
        await mount(t);
        final before = org.snapshot;
        final writes = store.writes;
        store.failWrite = true;
        await drop(t, a, b);
        expect(store.writes, writes + 1);
        expect(org.snapshot, same(before));
        expect(store.data, same(before));
        expect(find.byType(SnackBar), findsOneWidget);
        store.failWrite = false;
        final duplicate = await folder(b, 'A');
        await t.pumpAndSettle();
        final conflictBefore = org.snapshot;
        final conflictWrites = store.writes;
        await drop(t, a, b);
        expect(store.writes, conflictWrites);
        expect(org.snapshot, same(conflictBefore));
        expect(org.snapshot.folders[child]!.parent, a);
        expect(org.snapshot.folders[duplicate]!.parent, b);
      },
    );

    testWidgets(
      'tree change during folder drag rejects stale target submission',
      (t) async {
        await setup();
        final a = await folder(rootFolder, 'A');
        final b = await folder(rootFolder, 'B');
        await mount(t);
        final gesture = await start(t, a);
        await gesture.moveTo(t.getCenter(find.byKey(ValueKey('drop-$b'))));
        await t.pump();
        await folder(rootFolder, 'Changed');
        await t.pump();
        final writes = store.writes;
        await gesture.up();
        await t.pumpAndSettle();
        expect(org.snapshot.folders[a]!.parent, rootFolder);
        expect(store.writes, writes);
      },
    );
  });
}
