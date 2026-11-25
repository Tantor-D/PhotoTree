import 'dart:async';
import 'dart:convert';

import 'package:phototree/media/media_source.dart';
import 'package:phototree/library/favorites.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phototree/backup/backup_restore.dart';
import 'package:phototree/organization/organization.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/backup/backup_codec.dart';
import 'package:phototree/ui/restore_page.dart';
import 'package:phototree/ui/library_shell.dart';

import 'backup_restore_test.dart' show Harness;

void main() {
  testWidgets(
    'cancelling pending task keeps its next action distinct from file restore',
    (t) async {
      final h = Harness();
      await h.init();
      addTearDown(h.close);
      await t.pumpWidget(
        MaterialApp(
          home: RestorePage(restore: h.restore, intent: RestoreIntent.pending),
        ),
      );
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('取消本次准备'));
      await t.tap(find.text('取消本次准备'));
      await t.pumpAndSettle();
      expect(find.text('选择备份文件'), findsNothing);
      expect(find.text('重新处理待关联记录'), findsOneWidget);
      expect(find.text('返回备份与恢复'), findsOneWidget);
      expect(h.journal.prepares, 0);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets('picker resume refresh cannot bypass the file summary', (
    t,
  ) async {
    final h = Harness();
    await h.init();
    addTearDown(h.close);
    h.input.bytes = const BackupCodec().encode(h.document());
    await t.pumpWidget(MaterialApp(home: RestorePage(restore: h.restore)));
    await t.tap(find.text('选择备份文件'));
    await t.pumpAndSettle();
    expect(find.text('备份文件摘要'), findsOneWidget);
    await h.browser.refresh();
    await t.pumpAndSettle();
    expect(find.text('备份文件摘要'), findsOneWidget);
    expect(find.text('确认相册位置'), findsNothing);
    expect(find.text('开始关联相册'), findsOneWidget);
    expect(h.journal.prepares, 0);
    await t.pumpWidget(const SizedBox());
  });
  for (final kind in MediaKind.values) {
    testWidgets('manual restore picker offers only $kind candidates', (
      t,
    ) async {
      final h = Harness();
      const image = Photo(id: 21, directory: 'Pictures/Mixed/');
      const video = Photo(
        id: 22,
        directory: 'Pictures/Mixed/',
        kind: MediaKind.video,
      );
      h.source.items = [image, video];
      h.source.image = () async => base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
      );
      await h.init();
      addTearDown(h.close);
      final chosen = kind == MediaKind.video ? video : image;
      final other = kind == MediaKind.video ? image : video;
      h.input.bytes = const BackupCodec().encode(
        BackupDocument(
          organization: OrganizationSnapshot([], {}),
          albums: [],
          favorites: [
            BackupFavorite(
              identity: favoriteIdentity(chosen, 'old-library')!,
              filename: 'sample',
              unresolvedReason: 'original_permission_declined',
              mediaKind: kind,
            ),
          ],
        ),
      );
      await t.pumpWidget(MaterialApp(home: RestorePage(restore: h.restore)));
      await t.tap(find.text('选择备份文件'));
      await t.pumpAndSettle();
      await t.tap(find.text('开始关联相册'));
      await t.pumpAndSettle();
      await t.tap(find.text('核对收藏关联'));
      await t.pumpAndSettle();
      await t.tap(find.text('尚未匹配 · 1 条'));
      await t.pumpAndSettle();
      final favorite = find.text('sample');
      await t.ensureVisible(favorite);
      await t.tap(favorite);
      await t.pumpAndSettle();
      expect(
        find.text(
          'file-${chosen.id}.${kind == MediaKind.video ? "mp4" : "jpg"}',
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          'file-${other.id}.${kind == MediaKind.video ? "jpg" : "mp4"}',
        ),
        findsNothing,
      );
      expect(h.journal.prepares, 0);
      await t.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'normal UI requires directory confirmation and product replacement confirmation',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final h = Harness();
      await h.init();
      h.input.bytes = const BackupCodec().encode(h.document());
      await tester.pumpWidget(
        MaterialApp(home: RestorePage(restore: h.restore)),
      );
      await tester.tap(find.text('选择备份文件'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始关联相册'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '核对收藏关联'))
            .onPressed,
        isNull,
      );
      expect(h.journal.prepares, 0);
      await tester.ensureVisible(find.text('Old'));
      await tester.tap(find.text('Old'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('暂不关联（保留待关联记录）'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('核对收藏关联'));
      await tester.tap(find.text('核对收藏关联'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看变更预览'));
      await tester.pumpAndSettle();
      expect(find.text('待关联相册'), findsOneWidget);
      expect(h.journal.prepares, 0);
      await tester.ensureVisible(find.text('确认整体替换'));
      await tester.tap(find.text('确认整体替换'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(h.journal.prepares, 0);
      await tester.tap(find.text('确认整体替换'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认替换'));
      await tester.pumpAndSettle();
      expect(h.journal.prepares, 1);
      expect(h.fav.snapshot.pending.length, 1);
      await tester.pumpWidget(const SizedBox());
      h.close();
    },
  );
  testWidgets(
    'cancel picker and actual page disposal during active read leave private state unchanged',
    (tester) async {
      final h = Harness();
      await h.init();
      await tester.pumpWidget(
        MaterialApp(home: RestorePage(restore: h.restore)),
      );
      await tester.tap(find.text('选择备份文件'));
      await tester.pumpAndSettle();
      expect(find.textContaining('已取消选择备份'), findsOneWidget);
      expect(h.journal.prepares, 0);
      h.input.wait = Completer<Uint8List?>();
      await tester.tap(find.text('选择备份文件'));
      await tester.pump();
      expect(h.restore.busy, true);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(h.input.cancels, 1);
      expect(h.restore.busy, false);
      final token = Object();
      h.guard.acquire(token);
      h.guard.release(token);
      expect(h.journal.prepares, 0);
      h.close();
    },
  );
  testWidgets(
    'startup recovery blocked is visible in ordinary shell and retry entry',
    (tester) async {
      final h = Harness();
      h.journal.fail = 'read';
      await h.init();
      await tester.pumpWidget(
        MaterialApp(
          home: LibraryShell(
            browser: h.browser,
            organization: h.org,
            favorites: h.fav,
            restore: h.restore,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('私有数据恢复未完成'), findsOneWidget);
      await tester.tap(find.text('查看并重试恢复'));
      await tester.pumpAndSettle();
      expect(find.text('重试私有数据恢复'), findsOneWidget);
      h.journal.fail = null;
      await tester.tap(find.text('重试私有数据恢复'));
      await tester.pumpAndSettle();
      expect(h.restore.blocked, false);
      await tester.pumpWidget(const SizedBox());
      h.close();
    },
  );
  for (final kind in BackupInputFailureKind.values) {
    testWidgets(
      'input ${kind.name} explains the problem without platform details',
      (tester) async {
        final h = Harness();
        await h.init();
        h.input.error = BackupInputFailure(kind);
        await tester.pumpWidget(
          MaterialApp(home: RestorePage(restore: h.restore)),
        );
        await tester.tap(find.text('选择备份文件'));
        await tester.pumpAndSettle();
        expect(find.text(BackupInputFailure(kind).message), findsOneWidget);
        expect(find.textContaining('PlatformException'), findsNothing);
        expect(h.journal.prepares, 0);
        await tester.pumpWidget(const SizedBox());
        h.close();
      },
    );
  }
  testWidgets(
    'unexpected platform and parser errors use generic Chinese text',
    (tester) async {
      final h = Harness();
      await h.init();
      h.input.error = PlatformException(
        code: 'internal',
        message: 'provider-path-secret',
      );
      await tester.pumpWidget(
        MaterialApp(home: RestorePage(restore: h.restore)),
      );
      await tester.tap(find.text('选择备份文件'));
      await tester.pumpAndSettle();
      expect(find.text('操作未完成，请稍后重试。'), findsOneWidget);
      expect(find.textContaining('provider-path-secret'), findsNothing);
      h.input.error = null;
      h.input.bytes = Uint8List.fromList([255]);
      await tester.tap(find.text('选择备份文件'));
      await tester.pumpAndSettle();
      expect(find.text('备份无效：文件内容不完整或格式无效。私有数据未改变。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      h.close();
    },
  );
  for (final failure in [
    'before-prepare',
    'organization-written',
    'decision-written',
    'finish',
    'stale',
  ]) {
    testWidgets('apply $failure reports the actual private-data outcome', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(800, 1800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final h = Harness();
      await h.init();
      await h.org.create(rootFolder, 'before');
      h.input.bytes = const BackupCodec().encode(
        BackupDocument(
          organization: OrganizationSnapshot([
            const AlbumFolder('imported', rootFolder, 'after'),
          ], {}),
          albums: [],
          favorites: [],
        ),
      );
      await tester.pumpWidget(
        MaterialApp(home: RestorePage(restore: h.restore)),
      );
      await tester.tap(find.text('选择备份文件'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始关联相册'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('核对收藏关联'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看变更预览'));
      await tester.pumpAndSettle();
      if (failure == 'finish') {
        h.journal.fail = 'finish';
      } else if (failure == 'stale') {
        await h.org.create(rootFolder, 'new edit');
      } else {
        h.failPoint = failure;
      }
      await tester.tap(find.text('确认整体替换'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认替换'));
      await tester.pumpAndSettle();
      switch (failure) {
        case 'before-prepare':
          expect(find.textContaining('恢复未开始，当前私有数据未替换'), findsOneWidget);
        case 'organization-written':
          expect(find.text('恢复未完成，已还原原有私有数据'), findsOneWidget);
          expect(h.org.snapshot.folders.values.single.name, 'before');
        case 'decision-written':
          expect(find.text('恢复提交已完成'), findsOneWidget);
          expect(h.org.snapshot.folders.values.single.name, 'after');
        case 'finish':
          expect(find.textContaining('已保留数据库与恢复材料'), findsAtLeastNWidgets(1));
          expect(h.restore.blocked, true);
        case 'stale':
          expect(find.textContaining('预览已过期'), findsOneWidget);
          expect(h.journal.prepares, 0);
      }
      expect(find.textContaining('PlatformException'), findsNothing);
      expect(find.textContaining('DatabaseException'), findsNothing);
      expect(find.textContaining('Bad state:'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      h.close();
    });
  }
}
