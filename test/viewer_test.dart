import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/media/browser.dart';
import 'package:phototree/media/viewer_session.dart';
import 'package:phototree/ui/viewer_motion.dart';

import 'media_browser_test.dart' show FakeMedia, photo;

void main() {
  testWidgets('reduced motion settles automatic transitions without a ticker', (
    tester,
  ) async {
    final motion = ViewerMotion(vsync: tester, reduceAnimations: true);
    motion.layout(
      const Size(400, 800),
      const Size(800, 600),
      origin: const Rect.fromLTWH(10, 50, 90, 90),
    );
    expect(motion.rect, motion.base);
    expect(motion.background, 1);
    expect(motion.animating, false);
    var completions = 0;
    motion.close(null, () => completions++);
    expect(motion.background, 0);
    expect(motion.imageOpacity, 0);
    expect(completions, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(completions, 1);
    expect(tester.binding.transientCallbackCount, 0);
    motion.dispose();
  });

  testWidgets('reduced motion keeps direct input and page/dismiss thresholds', (
    tester,
  ) async {
    final motion = ViewerMotion(vsync: tester, reduceAnimations: true);
    motion.layout(const Size(400, 800), const Size(800, 600));
    motion.canNext = true;
    var pages = 0, dismisses = 0;
    motion.onPage = (_) {
      pages++;
      motion.resetPhoto(const Size(800, 600));
    };
    motion.onDismiss = () => dismisses++;
    void drag(Offset delta) {
      motion.down(
        const PointerDownEvent(pointer: 1, position: Offset(200, 400)),
      );
      motion.move(
        PointerMoveEvent(
          pointer: 1,
          position: const Offset(200, 400) + delta,
          timeStamp: const Duration(seconds: 1),
        ),
      );
      if (delta.dx != 0) expect(motion.page, delta.dx);
      if (delta.dy != 0) {
        expect(motion.rect.center.dy - motion.base.center.dy, delta.dy);
        expect(motion.background, lessThan(1));
      }
      motion.up(
        PointerUpEvent(
          pointer: 1,
          position: const Offset(200, 400) + delta,
          timeStamp: const Duration(seconds: 2),
        ),
      );
      expect(motion.animating, false);
    }

    drag(const Offset(-99, 0));
    expect(pages, 0);
    expect(motion.page, 0);
    drag(const Offset(-101, 0));
    expect(pages, 1);
    drag(const Offset(0, 199));
    expect(dismisses, 0);
    expect(motion.rect, motion.base);
    drag(const Offset(0, 201));
    expect(dismisses, 1);
    motion.dispose();
  });

  testWidgets('changing motion preference completes only a live transition', (
    tester,
  ) async {
    final motion = ViewerMotion(vsync: tester);
    motion.layout(const Size(400, 800), const Size(800, 600));
    const target = Rect.fromLTWH(20, 30, 90, 90);
    var completions = 0;
    motion.animate(target, backdrop: .4, done: () => completions++);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(motion.rect, isNot(target));
    motion.reduceAnimations = true;
    expect(motion.rect, target);
    expect(motion.background, .4);
    expect(completions, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(completions, 1);
    motion.reduceAnimations = false;
    motion.animate(motion.base, done: () => completions++);
    await tester.pump();
    motion.down(const PointerDownEvent(pointer: 1, position: Offset(200, 400)));
    final held = motion.rect;
    motion.reduceAnimations = true;
    expect(motion.rect, held);
    expect(completions, 1);
    motion.dispose();
  });

  testWidgets(
    'all four animation types can be grabbed without a geometry jump',
    (tester) async {
      final motion = ViewerMotion(vsync: tester);
      motion.layout(const Size(400, 800), const Size(800, 600));
      var exits = 0;
      for (final target in [
        motion.base,
        const Rect.fromLTWH(-200, 50, 1000, 750),
        motion.base,
        const Rect.fromLTWH(20, 30, 90, 90),
      ]) {
        for (var i = 0; i < 20; i++) {
          motion.animate(target, backdrop: .4, offset: 30, done: () => exits++);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 90));
          final before = motion.rect,
              background = motion.background,
              page = motion.page;
          motion.down(
            const PointerDownEvent(pointer: 1, position: Offset(200, 400)),
          );
          expect(motion.rect, before);
          expect(motion.background, background);
          expect(motion.page, page);
          await tester.pump(const Duration(milliseconds: 400));
          expect(motion.rect, before);
          motion.cancel(const PointerCancelEvent(pointer: 1));
          await tester.pumpAndSettle();
        }
      }
      expect(exits, 0);
      motion.dispose();
    },
  );
  testWidgets(
    'direction thresholds, zoom ownership, page bounds and one dismissal',
    (tester) async {
      final m = ViewerMotion(vsync: tester);
      m.layout(const Size(400, 800), const Size(800, 600));
      var pages = 0, dismisses = 0;
      m.canNext = true;
      m.onPage = (_) => pages++;
      m.onDismiss = () => dismisses++;
      void drag(Offset delta) {
        m.down(const PointerDownEvent(pointer: 1, position: Offset(200, 400)));
        m.move(
          PointerMoveEvent(
            pointer: 1,
            position: const Offset(200, 400) + delta,
            timeStamp: const Duration(seconds: 1),
          ),
        );
        m.up(
          PointerUpEvent(
            pointer: 1,
            position: const Offset(200, 400) + delta,
            timeStamp: const Duration(seconds: 2),
          ),
        );
      }

      drag(const Offset(-99, 0));
      await tester.pumpAndSettle();
      expect(pages, 0);
      drag(const Offset(-101, 0));
      await tester.pumpAndSettle();
      expect(pages, 1);
      m.resetPhoto(const Size(800, 600));
      drag(const Offset(150, 0));
      await tester.pumpAndSettle();
      expect(pages, 1);
      drag(const Offset(0, 199));
      await tester.pumpAndSettle();
      expect(dismisses, 0);
      drag(const Offset(0, 201));
      expect(dismisses, 1);
      m.resetPhoto(const Size(800, 600));
      m.animate(
        Rect.fromCenter(
          center: m.base.center,
          width: m.base.width * 2,
          height: m.base.height * 2,
        ),
      );
      await tester.pumpAndSettle();
      drag(const Offset(-200, 300));
      await tester.pumpAndSettle();
      expect(pages, 1);
      expect(dismisses, 1);
      expect(m.scale, 2);
      m.dispose();
    },
  );
  testWidgets(
    'rotation preserves zoom and normalized focus; suspension stops motion',
    (tester) async {
      final m = ViewerMotion(vsync: tester);
      m.layout(const Size(400, 800), const Size(800, 600));
      m.animate(
        Rect.fromCenter(
          center: m.base.center,
          width: m.base.width * 2.5,
          height: m.base.height * 2.5,
        ),
      );
      await tester.pumpAndSettle();
      for (var i = 0; i < 10; i++) {
        m.layout(const Size(800, 400), const Size(800, 600));
        expect(m.scale, closeTo(2.5, .0001));
        expect(m.rect.center, const Offset(400, 200));
        m.layout(const Size(400, 800), const Size(800, 600));
        expect(m.scale, closeTo(2.5, .0001));
        expect(m.rect.center, const Offset(200, 400));
      }
      m.animate(m.base);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      m.suspend();
      final held = m.rect;
      await tester.pump(const Duration(seconds: 1));
      expect(m.rect, held);
      expect(m.animating, false);
      m.dispose();
    },
  );
  test(
    'removed adjacent identity is skipped without changing current',
    () async {
      final source = FakeMedia()..items = [photo(1), photo(2), photo(3)];
      source.image = () =>
          Future<Uint8List>.error(StateError('unavailable fixture'));
      final browser = PhotoBrowser(source);
      await browser.refresh();
      final session = ViewerSession(browser, browser.photos, photo(3).key);
      expect(session.neighbor(1), photo(2).key);
      source.items = [photo(1), photo(3)];
      await browser.refresh();
      expect(session.currentKey, photo(3).key);
      expect(session.invalid, false);
      expect(session.neighbor(1), photo(1).key);
      session.turn(1);
      expect(session.currentKey, photo(1).key);
      expect(session.neighbor(1), isNull);
      session.dispose();
      browser.dispose();
    },
  );
  testWidgets(
    'pinch beyond both limits settles at one and four without changing gesture ownership',
    (tester) async {
      final m = ViewerMotion(vsync: tester);
      m.layout(const Size(400, 800), const Size(800, 600));
      var pages = 0, closes = 0;
      m.canNext = true;
      m.onPage = (_) => pages++;
      m.onDismiss = () => closes++;
      Future<void> pinch(double halfSpan) async {
        m.down(const PointerDownEvent(pointer: 1, position: Offset(100, 400)));
        m.down(const PointerDownEvent(pointer: 2, position: Offset(300, 400)));
        m.move(
          PointerMoveEvent(pointer: 1, position: Offset(200 - halfSpan, 400)),
        );
        m.move(
          PointerMoveEvent(pointer: 2, position: Offset(200 + halfSpan, 400)),
        );
        m.up(PointerUpEvent(pointer: 2, position: Offset(200 + halfSpan, 400)));
        expect(m.gesture, ViewerGesture.pinch);
        m.move(
          PointerMoveEvent(
            pointer: 1,
            position: Offset(200 - halfSpan + 80, 480),
          ),
        );
        m.up(
          PointerUpEvent(
            pointer: 1,
            position: Offset(200 - halfSpan + 80, 480),
          ),
        );
        await tester.pumpAndSettle();
      }

      await pinch(700);
      expect(m.scale, closeTo(4, .0001));
      await pinch(5);
      expect(m.scale, closeTo(1, .0001));
      expect(pages, 0);
      expect(closes, 0);
      m.dispose();
    },
  );
  testWidgets(
    'failed high-resolution load retains same-key preview and retry replaces it',
    (tester) async {
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
      );
      var calls = 0;
      final source = FakeMedia()..items = [photo(1)];
      source.image = () async {
        calls++;
        if (calls > 1) throw StateError('high-resolution read failed');
        return bytes;
      };
      final browser = PhotoBrowser(source);
      await browser.refresh();
      late ViewerSession session;
      await tester.runAsync(() async {
        session = ViewerSession(browser, browser.photos, photo(1).key);
        for (var i = 0; i < 50 && session.errors.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(session.errors, isNotEmpty);
      expect(session.image(photo(1).key), isNotNull);
      expect(session.heldBytes, 4);
      final preview = session.image(photo(1).key);
      source.image = () async => bytes;
      await tester.runAsync(() async {
        session.retry();
        expect(session.image(photo(1).key), same(preview));
        for (
          var i = 0;
          i < 50 && identical(preview, session.image(photo(1).key));
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(session.errors, isEmpty);
      expect(session.image(photo(1).key), isNot(same(preview)));
      expect(session.heldBytes, 4);
      session.dispose();
      expect(session.heldBytes, 0);
      browser.dispose();
    },
  );
  testWidgets(
    'missing return target fades the photo and takeover preserves visible opacity',
    (tester) async {
      final m = ViewerMotion(vsync: tester);
      m.layout(const Size(400, 800), const Size(800, 600));
      var exits = 0;
      m.close(null, () => exits++);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(m.imageOpacity, greaterThan(0));
      expect(m.imageOpacity, lessThan(1));
      final opacity = m.imageOpacity, rect = m.rect;
      m.down(const PointerDownEvent(pointer: 1, position: Offset(200, 400)));
      await tester.pump(const Duration(milliseconds: 400));
      expect(m.imageOpacity, opacity);
      expect(m.rect, rect);
      expect(exits, 0);
      m.cancel(const PointerCancelEvent(pointer: 1));
      await tester.pumpAndSettle();
      expect(m.imageOpacity, 1);
      expect(exits, 0);
      m.dispose();
    },
  );
  test('display and thumbnail jobs share four slots, display limited to two; stale rejected', () async {
    final gates = <Completer<Uint8List>>[];
    final source = FakeMedia()..items = List.generate(10, (i) => photo(i + 1));
    source.image = () {
      final c = Completer<Uint8List>();
      gates.add(c);
      return c.future;
    };
    final browser = PhotoBrowser(source);
    await browser.refresh();
    final requests = [
      for (var i = 0; i < 6; i++)
        browser
            .display(source.items[i], 4096, browser.generation)
            .then((_) => false, onError: (Object _) => true),
      for (var i = 6; i < 10; i++)
        browser
            .thumbnail(source.items[i], 512, browser.generation)
            .then((_) => false, onError: (Object _) => true),
    ];
    await Future<void>.delayed(Duration.zero);
    expect(gates.length, 4);
    expect(browser.maxActiveDisplay, 2);
    browser.suspend();
    for (final c in gates) {
      c.complete(Uint8List(1));
    }
    expect(await Future.wait(requests), everyElement(true));
    browser.dispose();
  });
  testWidgets(
    'session clears on permission recheck, ignores late images and exits for removed current',
    (tester) async {
      final source = FakeMedia()..items = [photo(1), photo(2), photo(3)];
      final gate = Completer<Uint8List>();
      source.image = () => gate.future;
      final b = PhotoBrowser(source);
      await b.refresh();
      final s = ViewerSession(b, b.photos, photo(2).key);
      b.suspend();
      gate.complete(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      expect(s.heldBytes, 0);
      expect(s.image(photo(2).key), isNull);
      source.items = [photo(1), photo(3)];
      await b.refresh();
      expect(s.invalid, true);
      expect(s.order, [photo(3).key, photo(2).key, photo(1).key]);
      s.dispose();
      b.dispose();
    },
  );
}
