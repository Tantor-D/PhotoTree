import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/backup/backup_export.dart';
import 'package:phototree/library/favorites.dart';
import 'package:phototree/media/browser.dart';
import 'package:phototree/media/media_source.dart';
import 'package:phototree/organization/organization.dart';
import 'package:phototree/ui/backup_page.dart';

import 'backup_export_test.dart' show Originals, Output;
import 'library_views_test.dart' show MemoryFavorites;
import 'media_browser_test.dart' show FakeMedia, photo;
import 'organization_test.dart' show MemoryOrganization;

class PermissionOriginals extends Originals {
  bool granted = false;
  @override
  Future<bool> permission({bool request = false}) async {
    if (request) granted = true;
    return granted;
  }
}

void main() {
  testWidgets('media refresh never publishes a misleading zero album summary', (
    tester,
  ) async {
    final media = FakeMedia()..items = [photo(1)];
    final browser = PhotoBrowser(media);
    await browser.refresh();
    final favorites = Favorites(MemoryFavorites(), browser);
    final organization = Organization(MemoryOrganization(), browser);
    await favorites.load();
    await organization.load();
    await tester.pumpWidget(
      MaterialApp(
        home: BackupPage(
          backup: BackupExport(
            organization,
            favorites,
            browser,
            Originals(),
            Output(),
          ),
        ),
      ),
    );
    expect(find.text('正在核对或暂不可用'), findsNothing);
    browser.suspend();
    await tester.pump();
    expect(find.text('正在核对或暂不可用'), findsOneWidget);
    await browser.refresh();
    await tester.pump();
    expect(find.text('正在核对或暂不可用'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    organization.dispose();
    favorites.dispose();
    browser.dispose();
  });

  testWidgets('stop preparation permits leaving and late read cannot save', (
    tester,
  ) async {
    final browser = PhotoBrowser(FakeMedia()..items = [photo(1), photo(2)]);
    await browser.refresh();
    final favorites = Favorites(MemoryFavorites(), browser);
    final organization = Organization(MemoryOrganization(), browser);
    await favorites.load();
    await organization.load();
    await favorites.set(photo(1), true);
    await favorites.set(photo(2), true);
    final originals = Originals()..delay = Completer<void>();
    final output = Output();
    final backup = BackupExport(
      organization,
      favorites,
      browser,
      originals,
      output,
    );
    await tester.pumpWidget(MaterialApp(home: BackupPage(backup: backup)));
    await tester.ensureVisible(find.widgetWithText(FilledButton, '导出备份'));
    await tester.tap(find.widgetWithText(FilledButton, '导出备份'));
    await tester.pump();
    expect(originals.calls, [1]);
    expect(find.text('正在准备收藏匹配资料：0 / 2 条'), findsOneWidget);
    await tester.ensureVisible(find.text('停止准备'));
    await tester.tap(find.text('停止准备'));
    await tester.pump();
    expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, true);
    await tester.pumpWidget(const SizedBox());
    originals.delay!.complete();
    await tester.pump();
    expect(originals.calls, [1]);
    expect(output.captured, isNull);
    expect(backup.busy, false);
    expect(tester.takeException(), isNull);
    organization.dispose();
    favorites.dispose();
    browser.dispose();
  });

  testWidgets(
    'first grant superseded by resume shows retry and never opens output; retry exports resolved favorite',
    (tester) async {
      final media = FakeMedia()..items = [photo(1)];
      final browser = PhotoBrowser(media);
      await browser.refresh();
      final favorites = Favorites(MemoryFavorites(), browser);
      final organization = Organization(MemoryOrganization(), browser);
      await favorites.load();
      await organization.load();
      await favorites.set(photo(1), true);
      final originals = PermissionOriginals(), output = Output();
      final backup = BackupExport(
        organization,
        favorites,
        browser,
        originals,
        output,
      );
      await tester.pumpWidget(MaterialApp(home: BackupPage(backup: backup)));
      await tester.ensureVisible(find.widgetWithText(FilledButton, '导出备份'));
      await tester.tap(find.widgetWithText(FilledButton, '导出备份'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('允许读取原始内容'), findsOneWidget);
      final firstPage = Completer<List<Photo>>(),
          resumedPage = Completer<List<Photo>>();
      var calls = 0;
      media.query = (after) async =>
          after == 0 ? (++calls == 1 ? firstPage : resumedPage).future : [];
      await tester.tap(find.text('允许读取原始内容'));
      await tester.pump();
      expect(calls, 1);
      final resumed = browser.refresh();
      await tester.pump();
      expect(calls, 2);
      firstPage.complete([photo(1)]);
      await tester.pumpAndSettle();
      expect(find.text('媒体列表正在刷新，请稍后重试导出。'), findsOneWidget);
      expect(output.captured, isNull);
      expect(backup.busy, false);
      expect(organization.busy, false);
      resumedPage.complete([photo(1)]);
      await tester.pump();
      await resumed;
      await tester.ensureVisible(find.widgetWithText(FilledButton, '导出备份'));
      await tester.tap(find.widgetWithText(FilledButton, '导出备份'));
      await tester.pumpAndSettle();
      expect(output.captured!.unresolvedCount, 0);
      await tester.ensureVisible(find.textContaining('缺少跨设备匹配资料 0 条'));
      expect(find.textContaining('缺少跨设备匹配资料 0 条'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      organization.dispose();
      favorites.dispose();
      browser.dispose();
    },
  );
}
