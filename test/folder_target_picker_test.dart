import 'package:phototree/media/media_source.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/organization/organization.dart';
import 'package:phototree/ui/folder_target_picker.dart';

import 'physical_operations_test.dart' show Harness;

void main() {
  Future<(Harness, String, String)> fixture() async {
    final h = Harness();
    await h.init();
    addTearDown(h.dispose);
    await h.organization.create(rootFolder, '旅行');
    final parent = h.organization.snapshot.children(rootFolder).single.id;
    await h.organization.create(parent, '山间');
    final child = h.organization.snapshot.children(parent).single.id;
    return (h, parent, child);
  }

  Future<void> show(
    WidgetTester t,
    Harness h, {
    String current = rootFolder,
    String? moving,
    double scale = 1,
  }) async {
    await t.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: FolderTargetPicker(
            organization: h.organization,
            currentParent: current,
            movingName: '测试相册',
            movingFolderId: moving,
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  bool enabled(WidgetTester t) =>
      t
          .widget<FilledButton>(find.byKey(const ValueKey('use-target-folder')))
          .onPressed !=
      null;

  testWidgets(
    'tree expands independently, selection is transient and stale tree disables confirmation',
    (t) async {
      final (h, parent, child) = await fixture();
      await show(t, h);
      final before = h.os.writes;
      expect(find.byKey(ValueKey('target-$child')), findsNothing);
      expect(enabled(t), isFalse);
      await t.tap(find.byKey(ValueKey('expand-target-$parent')));
      await t.pumpAndSettle();
      expect(find.byKey(ValueKey('target-$child')), findsOneWidget);
      expect(enabled(t), isFalse);
      await t.tap(find.byKey(ValueKey('target-$child')));
      await t.pumpAndSettle();
      expect(enabled(t), isTrue);
      expect(find.text('当前目标：根目录 / 旅行 / 山间'), findsOneWidget);
      expect(h.os.writes, before);
      await t.tap(find.byKey(ValueKey('expand-target-$parent')));
      await t.pumpAndSettle();
      expect(enabled(t), isTrue);
      expect(h.os.writes, before);
      await h.organization.rename(child, '改名');
      await t.pumpAndSettle();
      expect(enabled(t), isFalse);
      expect(find.text('原目标已不可用'), findsOneWidget);
    },
  );

  testWidgets(
    'current parent expands but cannot be selected, root remains a valid destination',
    (t) async {
      final (h, parent, child) = await fixture();
      await show(t, h, current: parent);
      expect(find.byKey(ValueKey('target-$child')), findsOneWidget);
      await t.tap(find.byKey(ValueKey('target-$parent')));
      await t.pumpAndSettle();
      expect(enabled(t), isFalse);
      await t.tap(find.byKey(ValueKey('expand-target-$parent')));
      await t.pumpAndSettle();
      expect(find.byKey(ValueKey('target-$child')), findsNothing);
      await t.tap(find.byKey(const ValueKey('target-$rootFolder')));
      await t.pumpAndSettle();
      expect(enabled(t), isTrue);
    },
  );

  testWidgets('moving a folder cannot select itself or its descendants', (
    t,
  ) async {
    final (h, parent, child) = await fixture();
    await show(t, h, moving: parent);
    await t.tap(find.byKey(ValueKey('expand-target-$parent')));
    await t.pumpAndSettle();
    expect(find.text('不能移到自身'), findsOneWidget);
    expect(find.text('不能移到后代文件夹'), findsOneWidget);
    await t.tap(find.byKey(ValueKey('target-$child')));
    await t.pumpAndSettle();
    expect(enabled(t), isFalse);
  });

  testWidgets('refresh invalidates selected folder without private writes', (
    t,
  ) async {
    final (h, parent, _) = await fixture();
    await show(t, h);
    await t.tap(find.byKey(ValueKey('target-$parent')));
    await t.pumpAndSettle();
    expect(enabled(t), isTrue);
    final writes = h.os.writes;
    await h.browser.refresh();
    await t.pumpAndSettle();
    expect(enabled(t), isFalse);
    expect(h.os.writes, writes);
  });

  testWidgets(
    'private folder move remains available without media permission',
    (t) async {
      final (h, parent, child) = await fixture();
      h.media.access = PhotoAccess.denied;
      await h.browser.refresh();
      await show(t, h, current: parent, moving: child);
      await t.tap(find.byKey(const ValueKey('target-$rootFolder')));
      await t.pumpAndSettle();
      expect(enabled(t), isTrue);
      expect(
        await h.organization.moveFolder(
          child,
          rootFolder,
          base: h.organization.snapshot,
          expectedParent: parent,
        ),
        isNull,
      );
      expect(h.organization.snapshot.folders[child]!.parent, rootFolder);
    },
  );

  for (final size in [
    const Size(320, 640),
    const Size(360, 640),
    const Size(412, 640),
    const Size(640, 320),
  ]) {
    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets('target tree controls fit $size scale $scale', (t) async {
        final (h, parent, _) = await fixture();
        t.view.physicalSize = size;
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        await show(t, h, current: parent, scale: scale);
        expect(t.takeException(), isNull);
        for (final finder in [
          find.text('取消'),
          find.byKey(const ValueKey('use-target-folder')),
        ]) {
          final rect = t.getRect(finder);
          expect(rect.top, greaterThanOrEqualTo(0));
          expect(rect.bottom, lessThanOrEqualTo(size.height));
        }
        expect(
          t.getSize(find.byKey(const ValueKey('use-target-folder'))).height,
          greaterThanOrEqualTo(48),
        );
      });
    }
  }
}
