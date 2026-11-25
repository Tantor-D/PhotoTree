import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/media/browser.dart';
import 'package:phototree/ui/photo_grid.dart';

import 'media_browser_test.dart' show photo;
import 'photo_grid_scroll_test.dart' show ScrollMedia;

void main() {
  for (final count in [1200, 50000]) {
    testWidgets(
      'restoring a deep anchor in $count items builds only nearby media tiles',
      (tester) async {
        tester.view.physicalSize = const Size(400, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final source = ScrollMedia()
          ..hold = true
          ..items = List.generate(count, (i) => photo(i + 1, added: 1000));
        final browser = PhotoBrowser(source);
        await browser.refresh();
        final position = GridPosition()
          ..anchor = browser.photos[count - 200].key;
        var tileBuilds = 0;
        final previous = debugOnRebuildDirtyWidget;
        debugOnRebuildDirtyWidget = (element, builtOnce) {
          previous?.call(element, builtOnce);
          if (!builtOnce && element.widget is PhotoTile) tileBuilds++;
        };
        addTearDown(() => debugOnRebuildDirtyWidget = previous);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PhotoGrid(browser: browser, position: position),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        final target = find.byWidgetPredicate(
          (w) =>
              w is PhotoTile && w.photo.key == browser.photos[count - 200].key,
        );
        expect(target, findsOneWidget);
        expect(
          tester.getRect(target).overlaps(const Rect.fromLTWH(0, 0, 400, 800)),
          isTrue,
        );
        final initialBuilds = tileBuilds;
        browser.suspend();
        await tester.pump();
        expect(find.byType(PhotoTile), findsNothing);
        tileBuilds = 0;
        // A native reload returns new metadata objects for the same identities.
        source.items = List.generate(count, (i) => photo(i + 1, added: 1000));
        await browser.refresh();
        await tester.pump();
        await tester.pump();
        expect(target, findsOneWidget);
        expect(
          tester.getRect(target).overlaps(const Rect.fromLTWH(0, 0, 400, 800)),
          isTrue,
        );
        final resumedBuilds = tileBuilds;
        await tester.pumpWidget(const SizedBox());
        browser.dispose();
        source.release();
        expect(
          initialBuilds,
          lessThan(300),
          reason: 'Restoring an anchor must not materialize all preceding rows',
        );
        expect(
          resumedBuilds,
          lessThan(300),
          reason: 'A permission-safe reload must also restore only nearby rows',
        );
      },
    );
  }
}
