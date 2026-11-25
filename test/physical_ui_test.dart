import 'package:phototree/ui/library_shell.dart';

import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/media/media_source.dart';
import 'package:phototree/media/physical_media.dart';
import 'package:phototree/storage/directory_access.dart';
import 'package:phototree/ui/photo_grid.dart';
import 'package:phototree/ui/media_operation_dialog.dart';
import 'package:phototree/ui/photo_viewer.dart';
import 'package:phototree/ui/physical_operations_page.dart';

import 'physical_operations_test.dart' show Harness;
import 'media_browser_test.dart' show photo;

class UiDirectoryAccess implements DirectoryAccess {
  DirectoryIdentity? requested;
  @override
  Future<DirectoryRequest> authorize(DirectoryIdentity directory) async {
    requested = directory;
    return DirectoryRequest.granted;
  }

  @override
  Future<DirectoryCapabilities> inspect(DirectoryIdentity directory) async =>
      const DirectoryCapabilities(
        status: DirectoryStatus.available,
        reason: '可访问',
      );
}

void main() {
  Future<Harness> ready() async {
    final h = Harness();
    h.media.image = () async => base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jw1kAAAAASUVORK5CYII=',
    );
    await h.init();
    return h;
  }

  testWidgets('removing preview page releases its guard without writes', (
    tester,
  ) async {
    final h = await ready();
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    addTearDown(h.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AnimatedBuilder(
          animation: h.ops,
          builder: (context, _) => Column(
            children: [
              Text(h.guard.held ? '保护中' : '已释放'),
              Expanded(
                child: ValueListenableBuilder<bool>(
                  valueListenable: visible,
                  builder: (context, show, _) => show
                      ? PhysicalOperationsPage(
                          operations: h.ops,
                          photos: h.media.items,
                        )
                      : const Text('预览页已移除'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(h.ops.preview, isNotNull);
    expect(h.guard.held, isTrue);
    visible.value = false;
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(h.ops.preview, isNull);
    expect(h.guard.held, isFalse);
    expect(h.access.writes, 0);
    expect(h.journal.writes, 0);
  });

  testWidgets('old route finishing exit cannot cancel a newly opened preview', (
    tester,
  ) async {
    final h = await ready();
    addTearDown(h.dispose);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: Text('照片')),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => PhysicalOperationsPage(
          operations: h.ops,
          photos: [h.media.items.first],
        ),
      ),
    );
    await tester.pumpAndSettle();
    final oldPreview = h.ops.preview!;
    navigator.currentState!.pop();
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => PhysicalOperationsPage(
          operations: h.ops,
          photos: [h.media.items.last],
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    final nextPreview = h.ops.preview;
    expect(nextPreview, isNotNull);
    expect(nextPreview, isNot(same(oldPreview)));
    expect(nextPreview!.items.single.snapshot.photo.id, h.media.items.last.id);
    await tester.pumpAndSettle();
    expect(h.ops.preview, same(nextPreview));
    expect(h.guard.held, isTrue);
    expect(h.access.writes, 0);
    expect(h.journal.writes, 0);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(h.guard.held, isFalse);
  });

  testWidgets(
    'removing an executing page does not stop its remaining confirmed work',
    (tester) async {
      final h = await ready();
      addTearDown(h.dispose);
      final release = Completer<void>();
      h.access.action = () async {
        await release.future;
        h.media.items.removeAt(0);
        return const PhysicalResult(PhysicalOutcome.confirmed);
      };
      await tester.pumpWidget(
        MaterialApp(
          home: PhysicalOperationsPage(
            operations: h.ops,
            photos: List.of(h.media.items),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final execution = h.ops.execute();
      await tester.pump();
      expect(h.ops.busy, isTrue);
      await tester.pumpWidget(const SizedBox());
      expect(h.ops.busy, isTrue);
      expect(h.guard.held, isTrue);
      release.complete();
      await execution;
      await tester.pumpAndSettle();
      expect(h.access.writes, 2);
      expect(
        h.ops.records.single.items.every(
          (item) => item.outcome == PhysicalOutcome.confirmed,
        ),
        isTrue,
      );
      expect(h.guard.held, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'parent removal during preparation leaves no ownerless preview or guard',
    (tester) async {
      final h = await ready();
      addTearDown(h.dispose);
      final gate = Completer<void>();
      h.access.preparing = () => gate.future;
      await tester.pumpWidget(
        MaterialApp(
          home: PhysicalOperationsPage(
            operations: h.ops,
            photos: List.of(h.media.items),
          ),
        ),
      );
      await tester.pump();
      expect(h.ops.busy, isTrue);
      expect(h.guard.held, isTrue);
      expect(h.ops.preview, isNull);
      await tester.pumpWidget(const SizedBox());
      gate.complete();
      await tester.pumpAndSettle();
      expect(h.ops.busy, isFalse);
      expect(h.ops.preview, isNull);
      expect(h.guard.held, isFalse);
      expect(h.access.writes, 0);
      expect(h.journal.writes, 0);
    },
  );

  testWidgets(
    'late preparation cleanup does not cancel a newer preview from another owner',
    (tester) async {
      final h = await ready();
      addTearDown(h.dispose);
      final gate = Completer<void>();
      h.access.preparing = () => gate.future;
      var transferred = false;
      void handoff() {
        if (transferred || h.ops.busy || h.ops.preview == null) return;
        transferred = true;
        h.ops.cancelPreview();
        // Another caller takes ownership before the abandoned page receives its
        // completed preparation Future. No widget or operation internals are set.
        h.ops.preparePhotos([h.media.items.last], kind: PhysicalKind.delete);
      }

      h.ops.addListener(handoff);
      await tester.pumpWidget(
        MaterialApp(
          home: PhysicalOperationsPage(
            operations: h.ops,
            photos: [h.media.items.first],
          ),
        ),
      );
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      gate.complete();
      await tester.pumpAndSettle();
      expect(transferred, isTrue);
      expect(
        h.ops.preview!.items.single.snapshot.photo.id,
        h.media.items.last.id,
      );
      expect(h.guard.held, isTrue);
      expect(h.access.writes, 0);
      expect(h.journal.writes, 0);
      h.ops.removeListener(handoff);
      h.ops.cancelPreview();
      expect(h.guard.held, isFalse);
    },
  );

  testWidgets(
    'move waits for target, replaces preview and shows actual suffix name',
    (tester) async {
      final h = await ready();
      h.media.items.add(photo(3, directory: 'Pictures/B/'));
      await h.browser.refresh();
      final selected = h.browser.photos.firstWhere((p) => p.id == 1);
      h.access.action = () async => PhysicalResult(
        PhysicalOutcome.confirmed,
        after: PhysicalPhotoSnapshot(
          photo: photo(1, directory: 'Pictures/B/'),
          libraryVersion: 'test-library',
          displayName: '1 (1).jpg',
          size: 32,
          mimeType: 'image/jpeg',
          modifiedSeconds: 2,
          generationModified: 2,
          sha256: 'a' * 64,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: PhysicalOperationsPage(
            operations: h.ops,
            photos: [selected],
            kind: PhysicalKind.move,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(h.ops.preview, isNull);
      expect(find.text('确认移动'), findsNothing);
      await tester.tap(find.text('选择目标相册'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('target-album-external_primary:Pictures/A/')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('use-target-album')));
      await tester.pumpAndSettle();
      expect(find.textContaining('已在目标相册，无需移动'), findsNothing);
      expect(h.ops.preview!.items.single.outcome, isNull);
      expect(h.access.writes, 0);
      await tester.tap(find.text('选择目标相册'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('target-album-external_primary:Pictures/B/')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('use-target-album')));
      await tester.pumpAndSettle();
      expect(h.ops.preview!.targetDirectory, 'Pictures/B/');
      expect(h.ops.preview!.items.single.outcome, isNull);
      await tester.ensureVisible(find.text('确认移动'));
      await tester.tap(find.text('确认移动'));
      await tester.pumpAndSettle();
      expect(h.access.writes, 1);
      expect(find.textContaining('实际文件名：1 (1).jpg'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      h.dispose();
    },
  );

  testWidgets(
    'target authorization rechecks without executing and same-directory result follows confirmation',
    (tester) async {
      final h = await ready();
      final access = UiDirectoryAccess();
      h.access.action = () async =>
          const PhysicalResult(PhysicalOutcome.unchanged);
      await tester.pumpWidget(
        MaterialApp(
          home: PhysicalOperationsPage(
            operations: h.ops,
            photos: [h.browser.photos.first],
            kind: PhysicalKind.move,
            directoryAccess: access,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择目标相册'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('target-album-external_primary:Pictures/A/')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('use-target-album')));
      await tester.pumpAndSettle();
      final before = h.ops.preview;
      expect(before!.items.single.outcome, isNull);
      await tester.tap(find.text('授权目标目录并重新核对'));
      await tester.pumpAndSettle();
      expect(access.requested!.path, 'Pictures/A/');
      expect(access.requested!.volume, 'external_primary');
      expect(h.ops.preview, isNot(same(before)));
      expect(h.access.writes, 0);
      await tester.ensureVisible(find.text('确认移动'));
      await tester.tap(find.text('确认移动'));
      await tester.pumpAndSettle();
      expect(
        h.access.writes,
        1,
      ); // Adapter call validates; unchanged means no physical write.
      expect(find.textContaining('已在目标相册，无需移动'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      h.dispose();
    },
  );

  test('pending and external-volume albums cannot become physical targets', () {
    expect(
      physicalAlbumDirectory(Album('@pending/old', 'Pictures/Test/', [])),
      isNull,
    );
    expect(
      physicalAlbumDirectory(
        Album('1234-ABCD:Pictures/Test/', 'Pictures/Test/', []),
      ),
      isNull,
    );
    expect(
      physicalAlbumDirectory(
        Album('external_primary:Pictures/Test/', 'Pictures/Test/', []),
      )?.path,
      'Pictures/Test/',
    );
  });

  testWidgets(
    'leaving failed private commit keeps protection and labels incomplete result',
    (tester) async {
      final h = await ready();
      h.access.action = () async {
        h.fs.failWrite = true;
        return const PhysicalResult(PhysicalOutcome.confirmed);
      };
      await tester.pumpWidget(
        MaterialApp(
          home: PhysicalOperationsPage(
            operations: h.ops,
            photos: [h.browser.photos.first],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认删除上述媒体'));
      await tester.pumpAndSettle();
      expect(h.ops.blocked, isTrue);
      expect(find.textContaining('媒体已处理，应用内记录待补齐'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(h.guard.held, isTrue);
      h.fs.failWrite = false;
      await h.ops.reconcile();
      expect(h.guard.held, isFalse);
      expect(h.access.writes, 1);
      h.dispose();
    },
  );

  testWidgets('preview cancellation releases guard without writing media', (
    tester,
  ) async {
    final h = await ready();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => PhysicalOperationsPage(
                    operations: h.ops,
                    photos: h.browser.photos,
                  ),
                ),
              ),
              child: const Text('开始'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('开始'));
    await tester.pumpAndSettle();
    expect(find.text('确认删除上述媒体'), findsOneWidget);
    expect(h.guard.held, isTrue);
    expect(h.access.writes, 0);
    await tester.tap(find.text('取消，不执行'));
    await tester.pumpAndSettle();
    expect(h.guard.held, isFalse);
    expect(h.access.writes, 0);
    await tester.pumpWidget(const SizedBox());
    h.dispose();
  });

  testWidgets(
    'explicit confirmation shows per-item result and reconcile never writes again',
    (tester) async {
      final h = await ready();
      await tester.pumpWidget(
        MaterialApp(
          home: PhysicalOperationsPage(
            operations: h.ops,
            photos: [h.browser.photos.first],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(h.access.writes, 0);
      await tester.tap(find.text('确认删除上述媒体'));
      await tester.pumpAndSettle();
      expect(h.access.writes, 1);
      expect(find.textContaining('已核对完成'), findsOneWidget);
      await tester.tap(find.text('重新核对历史结果（不重做）'));
      await tester.pumpAndSettle();
      expect(h.access.writes, 1);
      await tester.pumpWidget(const SizedBox());
      h.dispose();
    },
  );

  testWidgets(
    'permission narrowing retains only verified accessible selected identities',
    (tester) async {
      final h = await ready();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PhotoGrid(browser: h.browser, physical: h.ops),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择媒体'));
      await tester.pump();
      await tester.tap(find.text('全选当前列表'));
      await tester.pump();
      expect(find.text('已选 2 项'), findsOneWidget);
      h.media.access = PhotoAccess.limited;
      h.media.items = [h.media.items.first];
      await h.browser.refresh();
      await tester.pumpAndSettle();
      expect(find.text('已选 2 项'), findsNothing);
      expect(find.byType(PhotoTile), findsOneWidget);
      expect(find.text('已选 1 项'), findsOneWidget);
      expect(find.text('退出选择'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      h.dispose();
    },
  );

  testWidgets(
    'permission loss with photo menu open closes viewer without popping grid',
    (tester) async {
      final h = await ready();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PhotoGrid(browser: h.browser, physical: h.ops),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PhotoTile).first);
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('媒体操作'));
      await tester.pumpAndSettle();
      expect(find.text('删除媒体'), findsOneWidget);
      h.media.access = PhotoAccess.denied;
      await h.browser.refresh();
      await tester.pumpAndSettle();
      expect(find.byType(PhotoViewer), findsNothing);
      expect(find.text('删除媒体'), findsNothing);
      expect(find.byType(PhotoGrid), findsOneWidget);
      expect(h.access.writes, 0);
      await tester.pumpWidget(const SizedBox());
      h.dispose();
    },
  );

  testWidgets(
    'confirmed deletion of selected album returns to its valid parent',
    (tester) async {
      final h = await ready();
      final albumKey = h.media.items.first.albumKey;
      h.access.photos = List.of(h.media.items);
      h.access.action = () async {
        h.media.items.removeAt(0);
        return const PhysicalResult(PhysicalOutcome.confirmed);
      };
      await tester.pumpWidget(
        MaterialApp(
          home: LibraryShell(
            organization: h.organization,
            browser: h.browser,
            physical: h.ops,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('album-panel-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey(albumKey)));
      await tester.pumpAndSettle();
      expect(
        tester.widget<PhotoGrid>(find.byType(PhotoGrid)).albumKey,
        albumKey,
      );
      expect(find.text('A'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('album-panel-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('管理 A'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除真实相册'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('确认删除相册及上述媒体'));
      await tester.tap(find.text('确认删除相册及上述媒体'));
      await tester.pumpAndSettle();
      expect(h.access.directoryWrites, 1);
      expect(h.ops.records.single.directoryPrivateCommitted, isTrue);
      expect(h.organization.albums, isEmpty);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('所选相册暂不可用'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(PhotoGrid),
          matching: find.text('所有媒体'),
        ),
        findsOneWidget,
      );
      expect(h.organization.albums, isEmpty);
      await tester.pumpWidget(const SizedBox());
      h.dispose();
    },
  );

  testWidgets('permission-hidden selected album is not treated as deleted', (
    tester,
  ) async {
    final h = await ready();
    final albumKey = h.media.items.first.albumKey;
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryShell(
          organization: h.organization,
          browser: h.browser,
          physical: h.ops,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('album-panel-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey(albumKey)));
    await tester.pumpAndSettle();
    h.media.access = PhotoAccess.denied;
    await h.browser.refresh();
    await tester.pumpAndSettle();
    expect(find.text('所选相册暂不可用'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is Text &&
            w.data == '所有媒体' &&
            w.overflow == TextOverflow.ellipsis,
      ),
      findsNothing,
    );
    expect(h.access.directoryWrites, 0);
    h.media.access = PhotoAccess.full;
    await h.browser.refresh();
    await tester.pumpAndSettle();
    expect(tester.widget<PhotoGrid>(find.byType(PhotoGrid)).albumKey, albumKey);
    expect(find.text('A'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    h.dispose();
  });

  testWidgets('single photo action closes viewer before opening confirmation', (
    tester,
  ) async {
    final h = await ready();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PhotoGrid(browser: h.browser, physical: h.ops),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PhotoTile).first);
    await tester.pumpAndSettle();
    expect(find.byType(PhotoViewer), findsOneWidget);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('媒体操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除媒体'));
    await tester.pumpAndSettle();
    expect(find.byType(PhotoViewer), findsNothing);
    expect(find.byType(MediaOperationDialog), findsOneWidget);
    expect(find.text('永久删除 1 项媒体？'), findsOneWidget);
    expect(h.ops.preview, isNull);
    expect(h.access.writes, 0);
    await tester.pumpWidget(const SizedBox());
    h.dispose();
  });
}
