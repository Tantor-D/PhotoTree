import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/backup/backup_codec.dart';
import 'package:phototree/backup/backup_export.dart';
import 'package:phototree/library/favorites.dart';
import 'package:phototree/media/media_source.dart';
import 'package:phototree/organization/organization.dart';
import 'package:phototree/ui/backup_home_page.dart';
import 'package:phototree/ui/backup_page.dart';
import 'package:phototree/ui/backup_widgets.dart';
import 'package:phototree/ui/restore_page.dart';
import 'package:phototree/ui/visual_style.dart';

import 'backup_restore_test.dart' show Harness;
import 'backup_export_test.dart' show Output;

void main() {
  for (final size in [
    const Size(320, 640),
    const Size(360, 640),
    const Size(440, 640),
    const Size(640, 320),
  ]) {
    final width = size.width;
    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets(
        'backup tasks and staged recovery width $width font $scale height ${size.height}',
        (t) async {
          await t.binding.setSurfaceSize(size);
          addTearDown(() => t.binding.setSurfaceSize(null));
          final h = Harness();
          await h.init();
          addTearDown(h.close);
          final output = Output();
          final export = BackupExport(
            h.org,
            h.fav,
            h.browser,
            h.media,
            output,
            guard: h.guard,
          );
          final doc = BackupDocument(
            organization: OrganizationSnapshot([], {}),
            albums: [],
            favorites: [
              for (var i = 1; i <= 100; i++)
                BackupFavorite(
                  identity: favoriteIdentity(
                    Photo(
                      id: i,
                      directory: 'Pictures/Very/Long/Trip/Family/2026/',
                      kind: i.isEven ? MediaKind.video : MediaKind.image,
                    ),
                    'old',
                  )!,
                  filename: '假期的回忆与很长的原始文件名称-$i.${i.isEven ? "mp4" : "jpg"}',
                  unresolvedReason: 'missing_fingerprint',
                  mediaKind: i.isEven ? MediaKind.video : MediaKind.image,
                ),
            ],
          );
          h.input.bytes = const BackupCodec().encode(doc);
          Widget app(Widget page) => MaterialApp(
            theme: photoTreeTheme(
              scale == 2 ? Brightness.dark : Brightness.light,
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                padding: const EdgeInsets.only(bottom: 24),
                disableAnimations: scale == 2,
              ),
              child: child!,
            ),
            home: page,
          );
          Future<void> tap(String text) async {
            final f = find.text(text);
            if (f.evaluate().isEmpty) {
              await t.scrollUntilVisible(
                f,
                250,
                scrollable: find.byType(Scrollable).first,
                maxScrolls: 60,
              );
            }
            await t.ensureVisible(f);
            await t.pumpAndSettle();
            await t.tap(f);
            await t.pumpAndSettle();
            expect(t.takeException(), isNull);
          }

          await t.pumpWidget(
            app(BackupHomePage(backup: export, restore: h.restore)),
          );
          await t.pumpAndSettle();
          await t.scrollUntilVisible(
            find.text('导出备份'),
            180,
            scrollable: find.byType(Scrollable).first,
          );
          expect(find.text('导出备份'), findsOneWidget);
          expect(find.textContaining('系统，不自动迁移'), findsNothing);
          expect(t.takeException(), isNull);
          await t.pumpWidget(app(BackupPage(backup: export)));
          await t.pumpAndSettle();
          expect(t.takeException(), isNull);
          await t.pumpWidget(app(RestorePage(restore: h.restore)));
          await t.pumpAndSettle();
          await tap('选择备份文件');
          await tap('开始关联相册');
          await tap('核对收藏关联');
          await tap('尚未匹配 · 100 条');
          expect(find.textContaining('假期的回忆').evaluate().length, 8);
          await tap('下一页');
          expect(find.textContaining('2 / 13'), findsOneWidget);
          expect(find.textContaining('假期的回忆').evaluate().length, 8);
          await t.ensureVisible(find.byType(TextField));
          await t.enterText(find.byType(TextField), '名称-100.');
          await t.pumpAndSettle();
          expect(find.text('假期的回忆与很长的原始文件名称-100.mp4'), findsOneWidget);
          await tap('查看变更预览');
          await tap('确认整体替换');
          expect(find.textContaining('成功后将以本次操作前状态'), findsOneWidget);
          await tap('取消');
          expect(h.journal.prepares, 0);
          await tap('确认整体替换');
          await tap('确认替换');
          expect(h.fav.snapshot.pending.length, 100);
          expect(find.text('已保存，仍有待关联记录'), findsOneWidget);
          expect(t.takeException(), isNull);
          await t.pumpWidget(const SizedBox());
        },
      );
    }
  }
  testWidgets(
    'bounded records expose every result without rendering whole list',
    (t) async {
      final seen = <int>{};
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: BackupRecords<int>(
                items: List.generate(100, (i) => i),
                label: (i) => '$i',
                builder: (i) {
                  seen.add(i);
                  return ListTile(title: Text('记录$i'));
                },
              ),
            ),
          ),
        ),
      );
      for (var page = 0; page < 12; page++) {
        await t.ensureVisible(find.text('下一页'));
        await t.tap(find.text('下一页'));
        await t.pumpAndSettle();
      }
      expect(seen, Set.from(List.generate(100, (i) => i)));
      expect(find.text('记录99'), findsOneWidget);
      expect(find.text('记录0'), findsNothing);
    },
  );
}
