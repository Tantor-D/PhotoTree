import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/media/physical_media.dart';
import 'package:phototree/ui/media_operation_dialog.dart';
import 'package:phototree/ui/visual_style.dart';

import 'physical_operations_test.dart' show Harness;

void main() {
  Future<Harness> mount(
    WidgetTester t, {
    double scale = 1,
    bool accessible = false,
  }) async {
    final h = Harness();
    await h.init();
    addTearDown(h.dispose);
    t.view.physicalSize = const Size(320, 640);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(
        theme: photoTreeTheme(Brightness.light),
        builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(
            textScaler: TextScaler.linear(scale),
            accessibleNavigation: accessible,
          ),
          child: child!,
        ),
        home: Builder(
          builder: (c) => Scaffold(
            body: TextButton(
              onPressed: () => showMediaOperationDialog(
                c,
                operations: h.ops,
                photos: h.media.items,
                kind: PhysicalKind.delete,
              ),
              child: const Text('删除'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('删除'));
    await t.pumpAndSettle();
    return h;
  }

  for (final scale in [1.0, 2.0]) {
    testWidgets('compact delete cancel is zero write at text $scale', (
      t,
    ) async {
      final h = await mount(t, scale: scale);
      expect(find.text('永久删除 2 项媒体？'), findsOneWidget);
      expect(find.textContaining('Pictures/'), findsNothing);
      final action = find.byKey(const ValueKey('confirm-media-operation'));
      final label = find.descendant(of: action, matching: find.text('永久删除'));
      expect(
        (t.getCenter(action) - t.getCenter(label)).distance,
        lessThanOrEqualTo(1),
      );
      expect(t.getSize(action).height, greaterThanOrEqualTo(48));
      expect(find.text('PhotoTree 的备份无法恢复原文件。'), findsOneWidget);
      if (scale == 1) {
        final bin = find.byIcon(Icons.delete_outline);
        expect(
          t.getCenter(bin).dx,
          closeTo(t.getCenter(find.text('永久删除 2 项媒体？')).dx, 1),
        );
      }
      expect(h.ops.preview, isNull);
      await t.ensureVisible(find.text('取消'));
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(h.access.writes, 0);
      expect(h.access.authorizationGroups, isEmpty);
      expect(h.journal.writes, 0);
      expect(t.takeException(), isNull);
    });
  }
  testWidgets('one confirm executes once and shows lightweight success', (
    t,
  ) async {
    final h = await mount(t);
    final gate = Completer<PhysicalResult>();
    h.access.authorizing = () => gate.future;
    await t.tap(find.byKey(const ValueKey('confirm-media-operation')));
    await t.pump();
    expect(find.byKey(const ValueKey('confirm-media-operation')), findsNothing);
    gate.complete(const PhysicalResult(PhysicalOutcome.confirmed));
    await t.pumpAndSettle();
    expect(h.access.authorizationGroups.length, 1);
    expect(h.access.writes, 2);
    expect(find.byType(MediaOperationDialog), findsNothing);
    expect(find.text('已删除 2 项'), findsOneWidget);
  });
  testWidgets('success details dismiss feedback and preserve journal', (
    t,
  ) async {
    final h = await mount(t);
    await t.tap(find.byKey(const ValueKey('confirm-media-operation')));
    await t.pumpAndSettle();
    await t.tap(find.text('查看详情'));
    await t.pumpAndSettle();
    expect(find.text('已删除 2 项'), findsNothing);
    expect(find.text('1.jpg'), findsOneWidget);
    expect(find.text('2.jpg'), findsOneWidget);
    expect(h.access.writes, 2);
  });

  testWidgets('a new success replaces old feedback without a queued repeat', (
    t,
  ) async {
    final h = await mount(t);
    for (var i = 0; i < 2; i++) {
      if (i > 0) {
        await t.tap(find.text('删除'));
        await t.pumpAndSettle();
      }
      await t.tap(find.byKey(const ValueKey('confirm-media-operation')));
      await t.pumpAndSettle();
      expect(find.text('已删除 2 项'), findsOneWidget);
    }
    expect(h.ops.records.length, 2);
    await t.pump(const Duration(seconds: 4));
    await t.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    await t.pump(const Duration(seconds: 5));
    expect(find.byType(SnackBar), findsNothing);
  });

  for (final accessible in [false, true]) {
    testWidgets('success with detail action times out accessible=$accessible', (
      t,
    ) async {
      final h = await mount(t, accessible: accessible);
      await t.tap(find.byKey(const ValueKey('confirm-media-operation')));
      await t.pumpAndSettle();
      expect(find.text('已删除 2 项'), findsOneWidget);
      await t.pump(const Duration(seconds: 3));
      expect(find.text('已删除 2 项'), findsOneWidget);
      await t.pump(const Duration(seconds: 2));
      await t.pumpAndSettle();
      expect(find.text('已删除 2 项'), findsNothing);
      expect(h.access.writes, 2);
      expect(h.journal.writes, greaterThan(0));
    });
  }

  testWidgets(
    'removed dialog releases only its late preparation without execution',
    (t) async {
      final h = await mount(t);
      final gate = Completer<void>();
      h.access.preparing = () => gate.future;
      await t.tap(find.byKey(const ValueKey('confirm-media-operation')));
      await t.pump();
      await t.pumpWidget(const SizedBox());
      gate.complete();
      await t.pumpAndSettle();
      expect(h.ops.preview, isNull);
      expect(h.guard.held, isFalse);
      expect(h.access.authorizationGroups, isEmpty);
      expect(h.access.writes, 0);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('partial failure shows truthful counts and details on demand', (
    t,
  ) async {
    final h = await mount(t);
    h.access.action = () async => PhysicalResult(
      h.access.writes == 1 ? PhysicalOutcome.confirmed : PhysicalOutcome.failed,
    );
    await t.tap(find.byKey(const ValueKey('confirm-media-operation')));
    await t.pumpAndSettle();
    expect(find.text('已完成 1 项，1 项未完成'), findsOneWidget);
    expect(find.text('1.jpg'), findsNothing);
    await t.tap(find.text('查看详情'));
    await t.pumpAndSettle();
    expect(find.text('1.jpg'), findsOneWidget);
    expect(find.text('2.jpg'), findsOneWidget);
  });
}
