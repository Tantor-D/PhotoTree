import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/media/media_source.dart';
import 'package:phototree/media/browser.dart';
import 'package:phototree/media/physical_media.dart';
import 'package:phototree/ui/physical_operations_page.dart';

import 'physical_operations_test.dart' show Harness;
import 'media_browser_test.dart' show FakeMedia, photo;
import 'physical_ui_test.dart' show UiDirectoryAccess;

void main() {
  testWidgets(
    'authorization waits for the replacement resume refresh before preparing',
    (tester) async {
      final h = Harness();
      await h.init();
      await tester.pumpWidget(
        MaterialApp(
          home: PhysicalOperationsPage(
            operations: h.ops,
            photos: [h.browser.photos.first],
            kind: PhysicalKind.move,
            directoryAccess: UiDirectoryAccess(),
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
      expect(h.ops.preview, isNotNull);
      final originalRefresh = Completer<PhotoAccess>();
      final resumedRefresh = Completer<PhotoAccess>();
      var calls = 0;
      h.media.permissionQuery = () {
        calls++;
        return switch (calls) {
          1 => originalRefresh.future,
          2 => resumedRefresh.future,
          _ => Future.value(PhotoAccess.full),
        };
      };
      await tester.tap(find.text('授权目标目录并重新核对'));
      await tester.pump();
      expect(calls, 1);
      // The actual app's resume handler can replace the authorization refresh.
      final resumed = h.browser.refresh();
      expect(calls, 2);
      originalRefresh.complete(PhotoAccess.full);
      await tester.pump();
      expect(h.ops.preview, isNull);
      expect(h.access.writes, 0);
      resumedRefresh.complete(PhotoAccess.full);
      await resumed;
      await tester.pumpAndSettle();
      expect(
        h.ops.preview,
        isNotNull,
        reason: 'Granted authorization must finish its fresh preview after the current refresh, without requiring the user to select the same target again',
      );
      expect(h.access.writes, 0);
      await tester.pumpWidget(const SizedBox());
      h.dispose();
    },
  );
  testWidgets(
    'authorization rechecks after refresh replaces an in-flight read-only preparation',
    (tester) async {
      final h = Harness();
      await h.init();
      await tester.pumpWidget(
        MaterialApp(
          home: PhysicalOperationsPage(
            operations: h.ops,
            photos: [h.browser.photos.first],
            kind: PhysicalKind.move,
            directoryAccess: UiDirectoryAccess(),
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
      final nativeRead = Completer<void>();
      var preparing = 0;
      h.access.preparing = () async {
        preparing++;
        if (preparing == 1) await nativeRead.future;
      };
      await tester.tap(find.text('授权目标目录并重新核对'));
      await tester.pump();
      expect(preparing, 1);
      final permission = Completer<PhotoAccess>();
      h.media.permissionQuery = () => permission.future;
      final resumed = h.browser.refresh();
      nativeRead.complete();
      await tester.pump();
      expect(h.ops.preview, isNull);
      expect(h.access.writes, 0);
      permission.complete(PhotoAccess.full);
      await resumed;
      await tester.pumpAndSettle();
      expect(
        h.ops.preview,
        isNotNull,
        reason: 'A replacement refresh during native precheck must settle before a complete read-only retry',
      );
      expect(preparing, 2);
      expect(h.access.writes, 0);
      await tester.pumpWidget(const SizedBox());
      h.dispose();
    },
  );
  for (final end in ['background', 'dispose', 'denied', 'failed']) {
    test('current refresh waiters terminate safely on $end', () async {
      final media = FakeMedia()..items = [photo(1)];
      final browser = PhotoBrowser(media);
      await browser.refresh();
      final pending = Completer<PhotoAccess>();
      media.permissionQuery = () => pending.future;
      final refresh = browser.refresh();
      final first = browser.waitForRefresh();
      final second = browser.waitForRefresh();
      if (end == 'background') browser.suspend();
      if (end == 'dispose') browser.dispose();
      if (end == 'failed') {
        media.query = (_) async =>
            throw const MediaFailure(MediaFailureKind.query);
      }
      pending.complete(end == 'denied' ? PhotoAccess.denied : PhotoAccess.full);
      await refresh;
      expect(await first, isFalse);
      expect(await second, isFalse);
      if (end != 'dispose') browser.dispose();
    });
  }

  for (final change in ['permission', 'identity', 'library']) {
    testWidgets(
      'authorization does not accept a new $change after refresh is ready',
      (tester) async {
        final h = Harness();
        await h.init();
        await tester.pumpWidget(
          MaterialApp(
            home: PhysicalOperationsPage(
              operations: h.ops,
              photos: [h.browser.photos.first],
              kind: PhysicalKind.move,
              directoryAccess: UiDirectoryAccess(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('选择目标相册'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(
            const ValueKey('target-album-external_primary:Pictures/A/'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('use-target-album')));
        await tester.pumpAndSettle();
        final native = Completer<void>();
        h.access.preparing = () => native.future;
        await tester.tap(find.text('授权目标目录并重新核对'));
        await tester.pump();
        final permission = Completer<PhotoAccess>();
        h.media.permissionQuery = () => permission.future;
        if (change == 'identity') {
          h.media.items = h.media.items
              .map((p) => photo(p.id, added: 999))
              .toList();
        }
        if (change == 'library') h.media.version = 'replacement-library';
        final refresh = h.browser.refresh();
        native.complete();
        await tester.pump();
        permission.complete(
          change == 'permission' ? PhotoAccess.limited : PhotoAccess.full,
        );
        await refresh;
        await tester.pumpAndSettle();
        expect(h.browser.phase, BrowsePhase.ready);
        expect(h.ops.preview, isNull);
        expect(find.text('确认移动'), findsNothing);
        expect(h.access.writes, 0);
        expect(find.textContaining('媒体核对未完成'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        h.dispose();
      },
    );
  }

  testWidgets(
    'authorization stops after three read-only attempts without a preview',
    (tester) async {
      final h = Harness();
      await h.init();
      await tester.pumpWidget(
        MaterialApp(
          home: PhysicalOperationsPage(
            operations: h.ops,
            photos: [h.browser.photos.first],
            kind: PhysicalKind.move,
            directoryAccess: UiDirectoryAccess(),
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
      final gates = <Completer<void>>[];
      h.access.preparing = () {
        final gate = Completer<void>();
        gates.add(gate);
        return gate.future;
      };
      await tester.tap(find.text('授权目标目录并重新核对'));
      await tester.pump();
      for (var i = 0; i < 3; i++) {
        expect(gates.length, i + 1);
        final permission = Completer<PhotoAccess>();
        h.media.permissionQuery = () => permission.future;
        final refresh = h.browser.refresh();
        gates[i].complete();
        await tester.pump();
        permission.complete(PhotoAccess.full);
        await refresh;
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(gates.length, 3);
      expect(h.ops.preview, isNull);
      expect(h.access.writes, 0);
      expect(find.textContaining('媒体核对未完成'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      h.dispose();
    },
  );

  testWidgets(
    'wait includes scheduled observer debounce and does not create another query',
    (tester) async {
      final media = NotifyingMedia()..items = [photo(1)];
      final browser = PhotoBrowser(media);
      await browser.refresh();
      final query = Completer<List<Photo>>();
      var reads = 0;
      media.query = (after) {
        reads++;
        return after == 0 ? query.future : Future.value([]);
      };
      media.controller.add(null);
      var settled = false;
      final waiting = browser.waitForRefresh().then((value) {
        settled = true;
        return value;
      });
      await tester.pump(const Duration(milliseconds: 149));
      expect(settled, isFalse);
      expect(reads, 0);
      await tester.pump(const Duration(milliseconds: 1));
      expect(settled, isFalse);
      expect(reads, 1);
      query.complete([photo(1)]);
      await tester.pump();
      expect(await waiting, isTrue);
      expect(reads, 2);
      browser.dispose();
      await media.controller.close();
    },
  );
}

class NotifyingMedia extends FakeMedia {
  final controller = StreamController<void>.broadcast(sync: true);
  @override
  Stream<void> get changes => controller.stream;
}
