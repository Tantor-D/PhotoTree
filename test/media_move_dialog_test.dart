import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/media/physical_media.dart';
import 'package:phototree/storage/directory_access.dart';
import 'package:phototree/ui/album_target_picker.dart';
import 'package:phototree/organization/organization.dart';
import 'package:phototree/ui/media_operation_dialog.dart';

import 'physical_operations_test.dart' show Harness, snap;
import 'album_creation_test.dart' show PhysicalAccess;
import 'media_browser_test.dart' show photo;

class _Directories extends PhysicalAccess {
  DirectoryStatus status = DirectoryStatus.available;
  int requests = 0;
  Future<void> Function()? duringAuthorization;
  DirectoryRequest grantResult = DirectoryRequest.granted;
  @override
  Future<DirectoryCapabilities> inspect(DirectoryIdentity d) async =>
      DirectoryCapabilities(status: status, reason: 'test');
  @override
  Future<DirectoryRequest> authorize(DirectoryIdentity d) async {
    requests++;
    await duringAuthorization?.call();
    if (grantResult == DirectoryRequest.granted) {
      status = DirectoryStatus.available;
    }
    return grantResult;
  }
}

void main() {
  Future<Harness> mount(WidgetTester t, _Directories directories) async {
    final h = Harness(directories: directories);
    h.media.items = [photo(1), photo(2, directory: 'Pictures/B/')];
    await h.init();
    addTearDown(h.dispose);
    h.access.action = () async => PhysicalResult(
      PhysicalOutcome.confirmed,
      after: snap(photo(1, directory: 'Pictures/B/')),
    );
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) => Scaffold(
            body: TextButton(
              child: const Text('移动'),
              onPressed: () => showMediaOperationDialog(
                c,
                operations: h.ops,
                photos: [h.media.items.first],
                kind: PhysicalKind.move,
              ),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('移动'));
    await t.pumpAndSettle();
    expect(find.byType(AlbumTargetPicker), findsOneWidget);
    expect(h.access.writes, 0);
    expect(h.access.authorizationGroups, isEmpty);
    await t.tap(
      find.byKey(const ValueKey('target-album-external_primary:Pictures/B/')),
    );
    await t.pumpAndSettle();
    expect(h.access.writes, 0);
    await t.tap(find.byKey(const ValueKey('use-target-album')));
    await t.pumpAndSettle();
    expect(find.text('移到「B」'), findsOneWidget);
    return h;
  }

  testWidgets('target selection and cancel never prepare or authorize', (
    t,
  ) async {
    final d = _Directories();
    final h = await mount(t, d);
    await t.tap(find.text('取消'));
    await t.pumpAndSettle();
    expect(h.journal.writes, 0);
    expect(h.access.preparationSizes, isEmpty);
    expect(d.requests, 0);
  });
  testWidgets(
    'valid directory grant is reused and one confirmation executes move',
    (t) async {
      final d = _Directories();
      final h = await mount(t, d);
      await t.tap(find.byKey(const ValueKey('confirm-media-operation')));
      await t.pumpAndSettle();
      expect(d.requests, 0);
      expect(h.access.writes, 1);
      expect(h.access.authorizationGroups.length, 1);
      expect(find.text('已移动 1 项'), findsOneWidget);
      await t.pump(const Duration(seconds: 4));
      await t.pumpAndSettle();
      expect(find.text('已移动 1 项'), findsNothing);
      expect(h.ops.records.single.items.single.privateCommitted, true);
    },
  );
  for (final deny in [false, true]) {
    testWidgets('missing directory asks only when needed; denied=$deny', (
      t,
    ) async {
      final d = _Directories()..status = DirectoryStatus.needsAuthorization;
      if (deny) d.grantResult = DirectoryRequest.cancelled;
      final h = await mount(t, d);
      await t.tap(find.byKey(const ValueKey('confirm-media-operation')));
      await t.pumpAndSettle();
      expect(d.requests, 0);
      expect(h.access.writes, 0);
      await t.tap(find.text('选择此文件夹'));
      await t.pumpAndSettle();
      expect(d.requests, 1);
      expect(h.access.writes, deny ? 0 : 1);
      expect(h.access.authorizationGroups.length, deny ? 0 : 1);
      if (deny) expect(find.text('未获得相册访问权限，没有移动任何文件'), findsOneWidget);
    });
  }
  testWidgets(
    'replacement during directory authorization stops without writing',
    (t) async {
      final d = _Directories()..status = DirectoryStatus.needsAuthorization;
      final h = await mount(t, d);
      d.duringAuthorization = () async {
        h.media.items = [
          photo(1, added: 123),
          photo(2, directory: 'Pictures/B/'),
        ];
      };
      await t.tap(find.byKey(const ValueKey('confirm-media-operation')));
      await t.pumpAndSettle();
      await t.tap(find.text('选择此文件夹'));
      await t.pumpAndSettle();
      expect(h.access.writes, 0);
      expect(h.access.authorizationGroups, isEmpty);
      expect(find.textContaining('重新选择'), findsOneWidget);
    },
  );
  testWidgets(
    'organization path distinguishes duplicate names without disk paths',
    (t) async {
      final h = Harness();
      h.media.items = [
        photo(1, directory: 'Pictures/One/B/'),
        photo(2, directory: 'Pictures/Two/B/'),
      ];
      await h.init();
      addTearDown(h.dispose);
      await h.organization.create(rootFolder, '家庭');
      final folder = h.organization.snapshot.children(rootFolder).single.id;
      await h.organization.moveAlbum(
        h.media.items.last.albumKey,
        folder,
        generation: h.browser.generation,
      );
      final target = h.organization.albums.firstWhere(
        (a) => a.key == h.media.items.last.albumKey,
      );
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaOperationDialog(
              operations: h.ops,
              photos: [h.media.items.first],
              kind: PhysicalKind.move,
              target: target,
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('相册 / 家庭 / B'), findsOneWidget);
      expect(find.text('Pictures/Two/B/'), findsNothing);
    },
  );
}
