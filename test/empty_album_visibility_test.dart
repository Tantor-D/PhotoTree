import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/media/browser.dart';
import 'package:phototree/media/media_source.dart';
import 'package:phototree/organization/organization.dart';
import 'package:phototree/storage/directory_access.dart';
import 'package:phototree/ui/library_shell.dart';

import 'album_creation_test.dart' show CreationStore, PhysicalAccess;
import 'media_browser_test.dart' show FakeMedia, photo;

void main() {
  late CreationStore store;
  late PhysicalAccess access;
  late FakeMedia media;
  late PhotoBrowser browser;
  late Organization org;
  setUp(() async {
    store = CreationStore();
    access = PhysicalAccess();
    media = FakeMedia();
    browser = PhotoBrowser(media);
    await browser.refresh();
    org = Organization(store, browser, directories: access);
    await org.load();
  });
  tearDown(() {
    org.dispose();
    browser.dispose();
  });

  Future<String> create(String name) async {
    expect(
      await org.createAlbum(
        rootFolder,
        const DirectoryIdentity('external_primary', 'DCIM/'),
        name,
      ),
      isNull,
    );
    await org.refreshDirectories();
    return 'external_primary:DCIM/$name/';
  }

  Album album(String key) => org.albums.singleWhere((a) => a.key == key);

  test(
    'new empty retention survives persisted reload, first video consumes it',
    () async {
      final key = await create('New');
      expect(org.canHideEmptyAlbum(album(key)), isTrue);
      // Round trip the same descriptor representation used by the SQLite store.
      final saved = descriptorFrom(
        descriptorData(store.data.descriptors[key]!),
      );
      expect(saved.retainWhenEmpty, isTrue);
      await org.load();
      await org.refreshDirectories();
      expect(org.isHiddenEmptyAlbum(album(key)), isFalse);
      media.items = [
        const Photo(
          id: 1,
          directory: 'DCIM/New/',
          takenMs: 0,
          addedSeconds: 0,
          kind: MediaKind.video,
        ),
      ];
      await browser.refresh();
      await org.retryDiscovery();
      expect(store.data.descriptors[key]!.retainWhenEmpty, isFalse);
      media.items = [];
      await browser.refresh();
      await org.refreshDirectories();
      expect(org.isHiddenEmptyAlbum(album(key)), isTrue);
      await org.load();
      await org.refreshDirectories();
      expect(org.isHiddenEmptyAlbum(album(key)), isTrue);
      expect(
        access.writes,
        1,
      ); // Only the explicit creation wrote shared storage.
    },
  );

  test(
    'hide saves before publication, fails safely and permits explicit retry',
    () async {
      final key = await create('New');
      store.failWrite = true;
      expect(await org.hideEmptyAlbum(key), isNotNull);
      expect(org.isHiddenEmptyAlbum(album(key)), isFalse);
      store.failWrite = false;
      expect(await org.hideEmptyAlbum(key), isNull);
      expect(org.isHiddenEmptyAlbum(album(key)), isTrue);
      await org.load();
      await org.refreshDirectories();
      expect(org.isHiddenEmptyAlbum(album(key)), isTrue);
      expect(access.writes, 1);
    },
  );

  test('failed first-media save retains evidence until retry even after media disappears', () async {
    final key = await create('New');
    store.failWrite = true;
    media.items = [photo(1, directory: 'DCIM/New/')];
    await browser.refresh();
    await org.retryDiscovery();
    expect(org.discoveryError, isNotNull);
    media.items = [];
    await browser.refresh();
    await org.retryDiscovery();
    store.failWrite = false;
    await org.retryDiscovery();
    await org.refreshDirectories();
    expect(org.discoveryError, isNull);
    expect(store.data.descriptors[key]!.retainWhenEmpty, isFalse);
    expect(org.isHiddenEmptyAlbum(album(key)), isTrue);
  });

  test(
    'fresh contents and concurrent media invalidate a hide request',
    () async {
      final key = await create('New');
      access.reading = const DirectoryReading(
        DirectoryContents.content,
        '目录含内容',
      );
      expect(await org.hideEmptyAlbum(key), '目录含内容');
      expect(store.data.descriptors[key]!.retainWhenEmpty, isTrue);
      access.readGate = Completer<DirectoryReading>();
      final hiding = org.hideEmptyAlbum(key);
      media.items = [photo(1, directory: 'DCIM/New/')];
      await browser.refresh();
      access.readGate!.complete(
        const DirectoryReading(DirectoryContents.empty, '空'),
      );
      expect(await hiding, isNotNull);
      expect(org.isHiddenEmptyAlbum(album(key)), isFalse);
      expect(access.writes, 1);
    },
  );

  test(
    'uncertain directory or restricted media scope is never hidden as empty',
    () async {
      final key = await create('New');
      expect(await org.hideEmptyAlbum(key), isNull);
      for (final contents in [
        DirectoryContents.content,
        DirectoryContents.missing,
        DirectoryContents.failed,
        DirectoryContents.needsAuthorization,
      ]) {
        access.reading = DirectoryReading(contents, '不可当作空目录');
        await org.refreshDirectories();
        expect(
          org.isHiddenEmptyAlbum(album(key)),
          isFalse,
          reason: contents.name,
        );
      }
      access.reading = const DirectoryReading(DirectoryContents.empty, '空');
      for (final permission in [PhotoAccess.limited, PhotoAccess.denied]) {
        media.access = permission;
        await browser.refresh();
        await org.refreshDirectories();
        expect(org.isHiddenEmptyAlbum(album(key)), isFalse);
      }
      media.access = PhotoAccess.full;
      await browser.refresh();
      await org.refreshDirectories();
      access.readGate = Completer<DirectoryReading>();
      final refreshing = org.refreshDirectories();
      expect(org.isHiddenEmptyAlbum(album(key)), isFalse);
      access.readGate!.complete(
        const DirectoryReading(DirectoryContents.empty, '空'),
      );
      await refreshing;
      expect(org.isHiddenEmptyAlbum(album(key)), isTrue);
    },
  );

  test('legacy descriptor defaults to automatic visibility; malformed preference rejects', () {
    final legacy = {
      'sourceKey': 'external_primary:DCIM/Old/',
      'name': 'Old',
      'directory': 'DCIM/Old/',
      'pending': false,
    };
    expect(descriptorFrom(legacy).retainWhenEmpty, isFalse);
    expect(descriptorData(descriptorFrom(legacy)), legacy);
    expect(
      () => descriptorFrom({...legacy, 'retainWhenEmpty': 'true'}),
      throwsFormatException,
    );
    expect(
      () => descriptorFrom({...legacy, 'unexpected': true}),
      throwsFormatException,
    );
  });

  testWidgets(
    'hide menu clears current scope and restores original slots after new media',
    (t) async {
      final a = (await t.runAsync(() => create('A')))!;
      final b = (await t.runAsync(() => create('B')))!;
      final c = (await t.runAsync(() => create('C')))!;
      await t.pumpWidget(
        MaterialApp(
          home: LibraryShell(browser: browser, organization: org),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('album-panel-toggle')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(ValueKey(b)));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('album-panel-toggle')));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('管理 B'));
      await t.pumpAndSettle();
      await t.tap(find.text('隐藏空相册'));
      await t.pump(const Duration(milliseconds: 300));
      await t.runAsync(() => Future<void>.delayed(Duration.zero));
      await t.pumpAndSettle();
      expect(find.byKey(ValueKey(b)), findsNothing);
      expect(
        find.text('B'),
        findsNothing,
      ); // Also no stale selected album title.
      expect(find.textContaining('暂不可见的归类关系'), findsNothing);
      await t.tap(find.byTooltip('管理 C'));
      await t.pumpAndSettle();
      await t.tap(find.text('上移'));
      await t.pump(const Duration(milliseconds: 300));
      await t.runAsync(() => Future<void>.delayed(Duration.zero));
      await t.pumpAndSettle();
      expect(org.snapshot.albumOrders[rootFolder], [c, b, a]);
      expect(
        t.getTopLeft(find.byKey(ValueKey(c))).dy,
        lessThan(t.getTopLeft(find.byKey(ValueKey(a))).dy),
      );
      await t.pumpWidget(const SizedBox());
      media.items = [photo(1, directory: 'DCIM/B/')];
      await browser.refresh();
      await org.retryDiscovery();
      expect(org.isHiddenEmptyAlbum(album(b)), isFalse);
      expect(org.snapshot.albumOrders[rootFolder], [c, b, a]);
      expect(access.writes, 3);
    },
  );

  testWidgets(
    'verified legacy empty album is absent from sidebar, not deleted',
    (t) async {
      const key = 'external_primary:DCIM/Creative/';
      final store = CreationStore()
        ..data = OrganizationSnapshot(
          [],
          {},
          descriptors: {
            key: const AlbumDescriptor(
              sourceKey: key,
              name: 'Creative',
              directory: 'DCIM/Creative/',
              pending: false,
            ),
          },
        );
      final access = PhysicalAccess();
      final browser = PhotoBrowser(FakeMedia());
      await browser.refresh();
      final org = Organization(store, browser, directories: access);
      await org.load();
      await org.refreshDirectories();
      addTearDown(org.dispose);
      addTearDown(browser.dispose);
      await t.pumpWidget(
        MaterialApp(
          home: LibraryShell(browser: browser, organization: org),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('album-panel-toggle')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey(key)), findsNothing);
      expect(find.textContaining('暂不可见的归类关系'), findsNothing);
      expect(org.albums.single.key, key);
      expect(org.restoreAlbums.single.key, key);
      expect(org.snapshot.descriptors.containsKey(key), isTrue);
      expect(access.writes, 0);
    },
  );
}
