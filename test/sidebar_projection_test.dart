import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/media/browser.dart';
import 'package:phototree/media/media_source.dart';
import 'package:phototree/organization/organization.dart';
import 'package:phototree/ui/library_shell.dart';

import 'media_browser_test.dart' show FakeMedia, photo;
import 'organization_test.dart' show MemoryOrganization;

/// Counts the actual full-media projection used by Organization, rather than
/// timing a debug build or replacing the expensive behavior with a fake.
class _ProjectionCountingBrowser extends PhotoBrowser {
  _ProjectionCountingBrowser(super.source);

  int albumProjections = 0;

  @override
  List<Album> get albums {
    albumProjections++;
    return super.albums;
  }
}

void main() {
  for (final albumCount in [10, 100]) {
    testWidgets(
      'sidebar projection work stays bounded with $albumCount albums',
      (tester) async {
        final source = FakeMedia()
          ..items = List.generate(
            albumCount * 200,
            (i) => photo(i + 1, directory: 'Pictures/Album${i ~/ 200}/'),
          )
          ..image = () async => base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jw1kAAAAASUVORK5CYII=',
          );
        final browser = _ProjectionCountingBrowser(source);
        await browser.refresh();
        final organization = Organization(MemoryOrganization(), browser);
        await organization.load();
        addTearDown(browser.dispose);
        addTearDown(organization.dispose);
        tester.view.physicalSize = const Size(412, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            home: LibraryShell(browser: browser, organization: organization),
          ),
        );
        await tester.pumpAndSettle();
        browser.albumProjections = 0;
        await tester.tap(find.byKey(const ValueKey('album-panel-toggle')));
        await tester.pumpAndSettle();
        expect(find.text('Album0'), findsOneWidget);
        // Composition may read the view, but row count must not multiply scans
        // of every photo when opening the sidebar.
        expect(browser.albumProjections, lessThanOrEqualTo(6));

        // A subsequent media refresh must replace the displayed projection; the
        // optimization must not retain a list across builds or browser changes.
        source.items = [photo(1, directory: 'Pictures/RefreshedAlbum/')];
        await browser.refresh();
        await tester.pumpAndSettle();
        expect(find.text('RefreshedAlbum'), findsOneWidget);
        expect(find.text('Album0'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
