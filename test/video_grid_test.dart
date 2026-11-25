import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/library/views.dart';
import 'package:phototree/media/media_source.dart';
import 'package:phototree/ui/photo_grid.dart';

import 'physical_operations_test.dart' show Harness;

void main() {
  const image = Photo(id: 1, directory: 'Pictures/Mixed/');
  const video = Photo(
    id: 2,
    directory: 'Pictures/Mixed/',
    kind: MediaKind.video,
    durationMs: 3661000,
  );
  const unknown = Photo(
    id: 3,
    directory: 'Pictures/Video/',
    kind: MediaKind.video,
  );

  test('type views filter the same mixed collection and selection counts include both', () {
    final photos = [image, video, unknown];
    final now = DateTime(2026);
    expect(viewPhotos(photos, LibraryView.all, null, now), same(photos));
    expect(viewPhotos(photos, LibraryView.images, null, now), [image]);
    expect(viewPhotos(photos, LibraryView.videos, null, now), [video, unknown]);
    expect(mediaSelectionSummary(photos), '图片 1、视频 2');
    expect(albumsOf(photos).last.photos.single, unknown);
  });

  testWidgets(
    'mixed grid shows time badges and all-select includes both types',
    (t) async {
      final h = Harness();
      h.media.items = [image, video, unknown];
      h.media.image = () async => base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
      );
      await h.init();
      addTearDown(h.dispose);
      t.view.physicalSize = const Size(320, 700);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Scaffold(
              body: PhotoGrid(
                browser: h.browser,
                physical: h.ops,
                scopeTitle: '所有媒体',
                density: GridDensity.dense,
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('1:01:01'), findsOneWidget);
      expect(find.text('时长未知'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.tap(find.byTooltip('选择媒体'));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('全选当前列表'));
      await t.pumpAndSettle();
      expect(find.text('已选 3 项'), findsOneWidget);
      expect(find.text('图片 1、视频 2'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'denied video access is distinct from an authorized empty video view',
    (t) async {
      final h = Harness();
      h.media.items = [image];
      h.media.videoAccess = PhotoAccess.denied;
      await h.init();
      addTearDown(h.dispose);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PhotoGrid(browser: h.browser, view: LibraryView.videos),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('未获视频访问权限，请在系统设置中授权'), findsOneWidget);
      h.media.videoAccess = PhotoAccess.full;
      await h.browser.refresh();
      await t.pumpAndSettle();
      expect(find.text('没有媒体'), findsOneWidget);
      expect(find.text('未获视频访问权限，请在系统设置中授权'), findsNothing);
      await t.pumpWidget(const SizedBox());
    },
  );
}
