import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/library/views.dart';
import 'package:phototree/media/browser.dart';
import 'package:phototree/organization/organization.dart';
import 'package:phototree/ui/library_shell.dart';
import 'package:phototree/ui/photo_grid.dart';

import 'media_browser_test.dart' show FakeMedia, photo;
import 'organization_test.dart' show MemoryOrganization;

void main() {
  testWidgets(
    'sidebar exposes existing library shortcuts and routes each view',
    (t) async {
      final browser = PhotoBrowser(FakeMedia()..items = [photo(1)]);
      await browser.refresh();
      final org = Organization(MemoryOrganization(), browser);
      await org.load();
      addTearDown(org.dispose);
      addTearDown(browser.dispose);
      await t.pumpWidget(
        MaterialApp(
          home: LibraryShell(browser: browser, organization: org),
        ),
      );
      await t.pumpAndSettle();
      final generation = browser.generation;
      await t.tap(find.byKey(const ValueKey('album-panel-toggle')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('scope-all')), findsOneWidget);
      expect(find.text('收藏'), findsOneWidget);
      expect(find.text('最近'), findsOneWidget);
      await t.tap(find.text('收藏'));
      await t.pumpAndSettle();
      expect(
        t.widget<PhotoGrid>(find.byType(PhotoGrid)).view,
        LibraryView.favorite,
      );
      await t.tap(find.byKey(const ValueKey('album-panel-toggle')));
      await t.pumpAndSettle();
      await t.tap(find.text('最近'));
      await t.pumpAndSettle();
      expect(
        t.widget<PhotoGrid>(find.byType(PhotoGrid)).view,
        LibraryView.recent,
      );
      await t.tap(find.byKey(const ValueKey('album-panel-toggle')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('scope-all')));
      await t.pumpAndSettle();
      expect(t.widget<PhotoGrid>(find.byType(PhotoGrid)).view, LibraryView.all);
      expect(browser.generation, generation);
    },
  );
}
