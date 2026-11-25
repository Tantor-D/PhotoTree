import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/dev/motion_probe.dart';
import 'package:phototree/ui/motion.dart';

void main() {
  const cardKey = ValueKey('card');

  Future<void> showSample(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DragSpring(
            maxOffset: Offset(180, 180),
            child: SizedBox(key: cardKey, width: 120, height: 120),
          ),
        ),
      ),
    );
  }

  testWidgets(
    'touch stops the return and dragging continues from that position',
    (tester) async {
      await showSample(tester);
      final card = find.byKey(cardKey);
      final origin = tester.getCenter(card);

      final firstDrag = await tester.startGesture(origin);
      await firstDrag.moveBy(const Offset(48, 0));
      await tester.pump();
      await firstDrag.moveBy(const Offset(80, 50));
      await tester.pump();
      final released = tester.getCenter(card);
      expect((released - origin).distance, greaterThan(60));
      await firstDrag.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 70));

      final duringReturn = tester.getCenter(card);
      expect((duringReturn - origin).distance, greaterThan(10));
      expect(
        (duringReturn - origin).distance,
        lessThan((released - origin).distance),
      );

      final takeover = await tester.startGesture(duringReturn);
      await tester.pump(const Duration(milliseconds: 300));
      expect((tester.getCenter(card) - duringReturn).distance, lessThan(.01));

      // First movement passes the recognizer's drag threshold; subsequent motion
      // must add to the grabbed position, with no centre reset.
      await takeover.moveBy(const Offset(48, 0));
      await tester.pump();
      final afterThreshold = tester.getCenter(card);
      await takeover.moveBy(const Offset(10, 12));
      await tester.pump();
      expect(
        (tester.getCenter(card) - afterThreshold - const Offset(10, 12))
            .distance,
        lessThan(.01),
      );
      expect(afterThreshold.dx, greaterThanOrEqualTo(duringReturn.dx));

      await takeover.up();
      await tester.pumpAndSettle();
      expect((tester.getCenter(card) - origin).distance, lessThan(.01));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a cancelled grab returns to rest and disposal cancels tickers', (
    tester,
  ) async {
    await showSample(tester);
    final card = find.byKey(cardKey);
    final origin = tester.getCenter(card);
    final drag = await tester.startGesture(origin);
    await drag.moveBy(const Offset(48, 0));
    await tester.pump();
    await drag.moveBy(const Offset(50, 40));
    await tester.pump();
    await drag.cancel();
    await tester.pumpAndSettle();
    expect((tester.getCenter(card) - origin).distance, lessThan(.01));

    final nextDrag = await tester.startGesture(origin);
    await nextDrag.moveBy(const Offset(48, 0));
    await tester.pump();
    await nextDrag.moveBy(const Offset(70, 50));
    await tester.pump();
    await nextDrag.up();
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('backgrounding stops motion without a delayed resume jump', (
    tester,
  ) async {
    await showSample(tester);
    final card = find.byKey(cardKey);
    final origin = tester.getCenter(card);
    final drag = await tester.startGesture(origin);
    await drag.moveBy(const Offset(48, 0));
    await tester.pump();
    await drag.moveBy(const Offset(60, 40));
    await tester.pump();
    await drag.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(tester.binding.transientCallbackCount, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 1));
    expect((tester.getCenter(card) - origin).distance, lessThan(.01));
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'small and landscape layouts allow large text and card dragging',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      for (final size in [const Size(320, 568), const Size(640, 320)]) {
        tester.view.physicalSize = size;
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: const MotionProbePage(),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        final card = find.byKey(const ValueKey('motion-sample-card'));
        final origin = tester.getCenter(card);
        final drag = await tester.startGesture(origin);
        await drag.moveBy(const Offset(0, 48));
        await tester.pump();
        await drag.moveBy(const Offset(0, 16));
        await tester.pump();
        expect((tester.getCenter(card) - origin).distance, greaterThan(10));
        await drag.up();
        await tester.pumpAndSettle();
        expect((tester.getCenter(card) - origin).distance, lessThan(.01));
        expect(tester.takeException(), isNull);
      }
    },
  );
}
