import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/organization/organization.dart';
import 'package:phototree/ui/album_target_picker.dart';
import 'package:phototree/ui/physical_operations_page.dart';
import 'package:phototree/media/physical_media.dart';

import 'physical_operations_test.dart' show Harness;
import 'media_browser_test.dart' show FakeMedia, photo;
import 'organization_test.dart' show MemoryOrganization;
import 'album_creation_test.dart' show PhysicalAccess;

import 'package:phototree/media/browser.dart';
import 'package:phototree/media/media_source.dart';
import 'package:phototree/storage/directory_access.dart';

void main() {
  testWidgets(
    'empty real album selectable then revoked directory disables it',
    (t) async {
      final browser = PhotoBrowser(FakeMedia());
      await browser.refresh();
      final store = MemoryOrganization();
      const key = 'external_primary:Pictures/Empty/';
      store.data = OrganizationSnapshot(
        [],
        {},
        descriptors: {
          key: const AlbumDescriptor(
            sourceKey: key,
            directory: 'Pictures/Empty/',
            pending: false,
          ),
        },
      );
      final access = PhysicalAccess();
      final org = Organization(store, browser, directories: access);
      addTearDown(org.dispose);
      addTearDown(browser.dispose);
      await org.load();
      await org.refreshDirectories();
      expect(org.albums.single.availability, AlbumAvailability.empty);
      await t.pumpWidget(
        MaterialApp(
          home: AlbumTargetPicker(
            organization: org,
            canSelect: (a) =>
                physicalAlbumDirectory(a) != null &&
                (a.availability == AlbumAvailability.indexed ||
                    a.availability == AlbumAvailability.empty),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('target-album-$key')));
      await t.pumpAndSettle();
      expect(
        t
            .widget<FilledButton>(
              find.byKey(const ValueKey('use-target-album')),
            )
            .onPressed,
        isNotNull,
      );
      expect(access.writes, 0);
      access.reading = const DirectoryReading(
        DirectoryContents.needsAuthorization,
        '目录授权已失效',
      );
      await org.refreshDirectories();
      await t.pumpAndSettle();
      expect(find.text('目录授权已失效'), findsOneWidget);
      expect(
        t
            .widget<FilledButton>(
              find.byKey(const ValueKey('use-target-album')),
            )
            .onPressed,
        isNull,
      );
      await t.tap(find.byKey(const ValueKey('target-album-$key')));
      await t.pumpAndSettle();
      expect(
        t
            .widget<FilledButton>(
              find.byKey(const ValueKey('use-target-album')),
            )
            .onPressed,
        isNull,
      );
      expect(access.writes, 0);
    },
  );

  testWidgets('same-name targets keep distinct real paths and leaf identity', (
    t,
  ) async {
    final h = Harness();
    h.media.items = [
      photo(1, directory: 'Pictures/Trips/Same/'),
      photo(2, directory: 'DCIM/Same/'),
    ];
    await h.init();
    addTearDown(h.dispose);
    await h.organization.create(rootFolder, '旅行');
    final folder = h.organization.snapshot.children(rootFolder).single.id;
    final key = h.media.items.first.albumKey;
    await h.organization.moveAlbum(
      key,
      folder,
      generation: h.browser.generation,
    );
    await t.pumpWidget(
      MaterialApp(
        home: AlbumTargetPicker(
          organization: h.organization,
          canSelect: (a) => physicalAlbumDirectory(a) != null,
          initialAlbumKey: key,
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.byKey(ValueKey('target-album-$key')), findsOneWidget);
    expect(find.text('Pictures/Trips/Same/'), findsNWidgets(2));
    expect(find.text('DCIM/Same/'), findsOneWidget);
    expect(find.text('根目录 / 旅行 / Same'), findsOneWidget);
    await t.tap(
      find.byKey(ValueKey('target-album-${h.media.items.last.albumKey}')),
    );
    await t.pumpAndSettle();
    expect(find.text('根目录 / Same'), findsOneWidget);
    expect(find.text('DCIM/Same/'), findsNWidgets(2));
    expect(h.access.writes, 0);
    expect(h.ops.preview, isNull);
  });

  testWidgets(
    'tree folders navigate, leaf selection waits for use and cancel preserves preview',
    (t) async {
      final h = Harness();
      await h.init();
      addTearDown(h.dispose);
      await h.organization.create(rootFolder, '旅行');
      final folder = h.organization.snapshot.children(rootFolder).single.id;
      await h.organization.moveAlbum(
        h.media.items.first.albumKey,
        folder,
        generation: h.browser.generation,
      );
      await t.pumpWidget(
        MaterialApp(
          home: PhysicalOperationsPage(
            operations: h.ops,
            photos: h.media.items,
            kind: PhysicalKind.move,
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('选择目标相册'));
      await t.pumpAndSettle();
      expect(find.text('A'), findsNothing);
      await t.tap(find.byKey(ValueKey('target-folder-$folder')));
      await t.pumpAndSettle();
      expect(
        t
            .widget<FilledButton>(
              find.byKey(const ValueKey('use-target-album')),
            )
            .onPressed,
        isNull,
      );
      await t.tap(
        find.byKey(ValueKey('target-album-${h.media.items.first.albumKey}')),
      );
      await t.pumpAndSettle();
      expect(h.ops.preview, isNull);
      expect(h.access.writes, 0);
      expect(find.text('根目录 / 旅行 / A'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('use-target-album')));
      await t.pumpAndSettle();
      final old = h.ops.preview;
      expect(old, isNotNull);
      expect(h.access.writes, 0);
      await t.tap(find.text('选择目标相册'));
      await t.pumpAndSettle();
      expect(find.text('A'), findsOneWidget);
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(identical(h.ops.preview, old), isTrue);
      expect(h.access.writes, 0);
    },
  );
  testWidgets('removed target becomes unusable while picker is open', (
    t,
  ) async {
    final h = Harness();
    await h.init();
    addTearDown(h.dispose);
    await t.pumpWidget(
      MaterialApp(
        home: AlbumTargetPicker(
          organization: h.organization,
          canSelect: (_) => true,
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(
      find.byKey(ValueKey('target-album-${h.media.items.first.albumKey}')),
    );
    await t.pumpAndSettle();
    h.media.items = [];
    await h.browser.refresh();
    await t.pumpAndSettle();
    expect(
      t
          .widget<FilledButton>(find.byKey(const ValueKey('use-target-album')))
          .onPressed,
      isNull,
    );
    expect(h.access.writes, 0);
  });
  for (final width in [320.0, 360.0, 412.0, 800.0]) {
    testWidgets('target panel fits width $width at text scale two', (t) async {
      final h = Harness();
      await h.init();
      addTearDown(h.dispose);
      t.view.physicalSize = Size(width, width == 800 ? 320 : 700);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.pumpWidget(
        MaterialApp(
          builder: (c, w) => MediaQuery(
            data: MediaQuery.of(c).copyWith(
              textScaler: TextScaler.linear(2),
              padding: EdgeInsets.all(24),
            ),
            child: w!,
          ),
          home: AlbumTargetPicker(
            organization: h.organization,
            canSelect: (_) => true,
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(
        t.getSize(find.byKey(const ValueKey('use-target-album'))).height,
        greaterThanOrEqualTo(48),
      );
    });
  }
}
